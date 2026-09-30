// UEFI boot service driver that gives Windows a linear framebuffer on Virtualization.framework.
//
// The firmware drives virtio-gpu with EDK2's VirtioGpuDxe, whose Graphics Output Protocol is
// PixelBltOnly with no framebuffer. Windows Boot Manager needs a linear framebuffer, and without
// one the VM doesn't boot. This driver backs the GOP with a framebuffer in reserved RAM (much like
// QEMU's ramfb) and copies changed rows to the virtio-gpu scanout on a timer. Copying stops at
// ExitBootServices, where Windows' own virtio-gpu driver takes over later in the boot.
//
// The framebuffer is sized for the mode the virtio-gpu is in when the driver finds it, which follows
// the VM's display size, up to 1920x1200. Above that, and for display sizes it doesn't list, where
// the firmware picks 8192x4320, the driver switches to the largest mode within 1920x1200. Larger
// modes stay Blt-only and can't be set.
//
// On load, the driver registers itself as a Driver#### option with a short-form device path, so the
// firmware loads it on every boot from whichever volume holds it: the installation media at first,
// then the Windows EFI system partition.

#include "efi.h"

#define MAX_GOPS 8
#define MAX_WIDTH 1920
#define MAX_HEIGHT 1200
#define FLUSH_INTERVAL 400000 // 40 ms, in 100 ns units

static EFI_GUID GraphicsOutputProtocolGuid = {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}};
static EFI_GUID DevicePathProtocolGuid = {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID ExitBootServicesEventGroup = {0x27abf055, 0xb1b8, 0x4c26, {0x80, 0x48, 0x74, 0x8f, 0x37, 0xba, 0xa2, 0xdf}};
static EFI_GUID GlobalVariableGuid = {0x8be4df61, 0x93ca, 0x11d2, {0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c}};
// Installed once the driver is resident, so that a second load is a no-op.
static EFI_GUID ResidentProtocolGuid = {0x6f0b3a51, 0x2c7e, 0x4b8e, {0x9a, 0x31, 0x5e, 0x77, 0x0c, 0x1d, 0x4f, 0x92}};

static CHAR16 DriverPath[] = L"\\EFI\\tart\\framebuffer.efi";
static CHAR16 DriverDescription[] = L"Tart framebuffer";

static EFI_BOOT_SERVICES *BS;

static UINT32 *Framebuffer;
static UINT32 *Shadow;
static UINTN FramebufferSize;
static BOOLEAN Flushing;
static EFI_EVENT FlushTimer;

// The virtio-gpu GOP, the only one with a device path
static EFI_GRAPHICS_OUTPUT_PROTOCOL *Device;
static EFI_GOP_BLT DeviceBlt;

// Every GOP advertises the framebuffer, including the console splitter's
static EFI_GRAPHICS_OUTPUT_PROTOCOL *Gops[MAX_GOPS];
static EFI_GOP_SET_MODE GopSetMode[MAX_GOPS];
static EFI_GOP_QUERY_MODE GopQueryMode[MAX_GOPS];
static UINTN GopCount;
static VOID *GopRegistration;

void *memcpy(void *dst, const void *src, UINTN n) {
  UINT8 *d = dst;
  const UINT8 *s = src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memset(void *dst, int c, UINTN n) {
  UINT8 *d = dst;
  while (n--) *d++ = (UINT8)c;
  return dst;
}

static BOOLEAN MemEqual(const void *a, const void *b, UINTN n) {
  const UINT8 *x = a, *y = b;
  while (n--) {
    if (*x++ != *y++) return FALSE;
  }
  return TRUE;
}

static UINTN StrSize(const CHAR16 *s) {
  UINTN n = 0;
  while (s[n]) n++;
  return (n + 1) * sizeof(CHAR16);
}

static UINT32 Width(void) { return Device->Mode->Info->HorizontalResolution; }
static UINT32 Height(void) { return Device->Mode->Info->VerticalResolution; }

static UINTN ModeSize(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  return (UINTN)info->HorizontalResolution * info->VerticalResolution * sizeof(UINT32);
}

static BOOLEAN WithinCap(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  return info->HorizontalResolution <= MAX_WIDTH && info->VerticalResolution <= MAX_HEIGHT;
}

static BOOLEAN Fits(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  return Framebuffer && info && WithinCap(info) && ModeSize(info) <= FramebufferSize;
}

static void AdvertiseFramebuffer(EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
  info->PixelInformation = (EFI_PIXEL_BITMASK){0};
  info->PixelsPerScanLine = info->HorizontalResolution;
}

static void PatchModes(void) {
  for (UINTN i = 0; i < GopCount; i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *mode = Gops[i]->Mode;
    if (!mode || !Fits(mode->Info)) continue;
    AdvertiseFramebuffer(mode->Info);
    mode->FrameBufferBase = (EFI_PHYSICAL_ADDRESS)(UINTN)Framebuffer;
    mode->FrameBufferSize = ModeSize(mode->Info);
  }
}

static int GopIndex(EFI_GRAPHICS_OUTPUT_PROTOCOL *gop) {
  for (UINTN i = 0; i < GopCount; i++) {
    if (Gops[i] == gop) return (int)i;
  }
  return -1;
}

static void Push(UINTN x, UINTN y, UINTN width, UINTN height) {
  if (!Flushing || x >= Width() || y >= Height()) return;
  if (width > Width() - x) width = Width() - x;
  if (height > Height() - y) height = Height() - y;
  if (!width || !height) return;

  DeviceBlt(Device, (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)Framebuffer, EfiBltBufferToVideo, x, y, x, y, width, height,
            Width() * 4);
}

// Windows writes to the framebuffer directly, so push whichever rows changed since the last flush.
static void EFIAPI Flush(EFI_EVENT event, VOID *context) {
  if (!Flushing || !Fits(Device->Mode->Info)) return;

  UINTN stride = Width() * 4;
  UINTN runStart = 0;
  BOOLEAN inRun = FALSE;

  for (UINTN row = 0; row < Height(); row++) {
    UINT8 *current = (UINT8 *)Framebuffer + row * stride;
    UINT8 *previous = (UINT8 *)Shadow + row * stride;

    if (!MemEqual(current, previous, stride)) {
      memcpy(previous, current, stride);
      if (!inRun) {
        runStart = row;
        inRun = TRUE;
      }
    } else if (inRun) {
      Push(0, runStart, Width(), row - runStart);
      inRun = FALSE;
    }
  }

  if (inRun) Push(0, runStart, Width(), Height() - runStart);
}

static void EFIAPI StopFlushing(EFI_EVENT event, VOID *context) {
  // VirtioGpuDxe resets the device at ExitBootServices
  Flushing = FALSE;
}

static EFI_STATUS EFIAPI QueryMode(EFI_GRAPHICS_OUTPUT_PROTOCOL *this, UINT32 mode, UINTN *size,
                                   EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **info) {
  int i = GopIndex(this);
  if (i < 0) return EFI_INVALID_PARAMETER;

  EFI_STATUS status = GopQueryMode[i](this, mode, size, info);
  if (!EFI_ERROR(status) && info && Fits(*info)) AdvertiseFramebuffer(*info);
  return status;
}

static EFI_STATUS EFIAPI SetMode(EFI_GRAPHICS_OUTPUT_PROTOCOL *this, UINT32 mode) {
  int i = GopIndex(this);
  if (i < 0) return EFI_INVALID_PARAMETER;

  if (Framebuffer) {
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info;
    UINTN size;
    if (EFI_ERROR(GopQueryMode[i](this, mode, &size, &info))) return EFI_UNSUPPORTED;
    BOOLEAN fits = Fits(info);
    BS->FreePool(info);
    if (!fits) return EFI_UNSUPPORTED;
  }

  EFI_STATUS status = GopSetMode[i](this, mode);
  if (!EFI_ERROR(status) && Framebuffer) {
    PatchModes();
    memset(Shadow, 0, FramebufferSize);
  }
  return status;
}

// Firmware drawing goes to the framebuffer too, so that it stays the single source of truth.
static EFI_STATUS EFIAPI Blt(EFI_GRAPHICS_OUTPUT_PROTOCOL *this, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *buffer,
                             EFI_GRAPHICS_OUTPUT_BLT_OPERATION operation, UINTN sx, UINTN sy, UINTN dx, UINTN dy,
                             UINTN width, UINTN height, UINTN delta) {
  if (!Fits(Device->Mode->Info)) return DeviceBlt(this, buffer, operation, sx, sy, dx, dy, width, height, delta);

  EFI_GRAPHICS_OUTPUT_BLT_PIXEL *fb = (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)Framebuffer;
  UINTN fbWidth = Width(), fbHeight = Height();

  if (!delta) delta = width * sizeof(EFI_GRAPHICS_OUTPUT_BLT_PIXEL);

  switch (operation) {
  case EfiBltVideoFill:
    for (UINTN y = 0; y < height && dy + y < fbHeight; y++) {
      for (UINTN x = 0; x < width && dx + x < fbWidth; x++) fb[(dy + y) * fbWidth + dx + x] = *buffer;
    }
    Push(dx, dy, width, height);
    return EFI_SUCCESS;

  case EfiBltBufferToVideo:
    for (UINTN y = 0; y < height && dy + y < fbHeight; y++) {
      EFI_GRAPHICS_OUTPUT_BLT_PIXEL *src = (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)((UINT8 *)buffer + (sy + y) * delta) + sx;
      for (UINTN x = 0; x < width && dx + x < fbWidth; x++) fb[(dy + y) * fbWidth + dx + x] = src[x];
    }
    Push(dx, dy, width, height);
    return EFI_SUCCESS;

  case EfiBltVideoToBltBuffer:
    for (UINTN y = 0; y < height && sy + y < fbHeight; y++) {
      EFI_GRAPHICS_OUTPUT_BLT_PIXEL *dst = (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)((UINT8 *)buffer + (dy + y) * delta) + dx;
      for (UINTN x = 0; x < width && sx + x < fbWidth; x++) dst[x] = fb[(sy + y) * fbWidth + sx + x];
    }
    return EFI_SUCCESS;

  case EfiBltVideoToVideo:
    for (UINTN y = 0; y < height; y++) {
      if (sy + y >= fbHeight || dy + y >= fbHeight) continue;
      for (UINTN x = 0; x < width; x++) {
        if (sx + x >= fbWidth || dx + x >= fbWidth) continue;
        fb[(dy + y) * fbWidth + dx + x] = fb[(sy + y) * fbWidth + sx + x];
      }
    }
    Push(dx, dy, width, height);
    return EFI_SUCCESS;

  default:
    return EFI_INVALID_PARAMETER;
  }
}

static EFI_STATUS AllocateFramebuffer(const EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info) {
  EFI_PHYSICAL_ADDRESS address;
  UINTN size = ModeSize(info);

  // Reserved memory, so that Windows keeps its hands off the framebuffer it's been given
  EFI_STATUS status = BS->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, EFI_SIZE_TO_PAGES(size), &address);
  if (EFI_ERROR(status)) return status;

  status = BS->AllocatePool(EfiBootServicesData, size, (VOID **)&Shadow);
  if (EFI_ERROR(status)) return status;

  Framebuffer = (UINT32 *)(UINTN)address;
  FramebufferSize = size;
  memset(Framebuffer, 0, size);
  memset(Shadow, 0, size);
  return EFI_SUCCESS;
}

// Switches the GOP to its largest mode within the cap if the current one is above it, and returns
// whether the current mode is within the cap
static BOOLEAN LimitMode(UINTN i) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = Gops[i];
  if (WithinCap(gop->Mode->Info)) return TRUE;

  UINT32 best = gop->Mode->MaxMode;
  UINTN bestSize = 0;
  for (UINT32 mode = 0; mode < gop->Mode->MaxMode; mode++) {
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info;
    UINTN size;
    if (EFI_ERROR(GopQueryMode[i](gop, mode, &size, &info))) continue;

    if (WithinCap(info) && ModeSize(info) > bestSize) {
      best = mode;
      bestSize = ModeSize(info);
    }
    BS->FreePool(info);
  }

  return best < gop->Mode->MaxMode && !EFI_ERROR(GopSetMode[i](gop, best)) && WithinCap(gop->Mode->Info);
}

static void Adopt(EFI_HANDLE handle) {
  EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = NULL;
  VOID *devicePath = NULL;

  if (EFI_ERROR(BS->HandleProtocol(handle, &GraphicsOutputProtocolGuid, (VOID **)&gop)) || !gop) return;
  if (GopIndex(gop) >= 0 || GopCount == MAX_GOPS) return;

  UINTN i = GopCount++;
  Gops[i] = gop;
  GopSetMode[i] = gop->SetMode;
  GopQueryMode[i] = gop->QueryMode;
  gop->SetMode = SetMode;
  gop->QueryMode = QueryMode;

  if (!Device && !EFI_ERROR(BS->HandleProtocol(handle, &DevicePathProtocolGuid, &devicePath)) && devicePath &&
      gop->Mode && gop->Mode->Info && LimitMode(i) && !EFI_ERROR(AllocateFramebuffer(gop->Mode->Info))) {
    Device = gop;
    DeviceBlt = gop->Blt;
    gop->Blt = Blt;
    Flushing = TRUE;
    BS->SetTimer(FlushTimer, TimerPeriodic, FLUSH_INTERVAL);
  }

  PatchModes();
}

static void EFIAPI AdoptNewGops(EFI_EVENT event, VOID *context) {
  EFI_HANDLE *handles;
  UINTN count;

  while (!EFI_ERROR(BS->LocateHandleBuffer(ByRegisterNotify, NULL, GopRegistration, &count, &handles))) {
    for (UINTN i = 0; i < count; i++) Adopt(handles[i]);
    BS->FreePool(handles);
  }
}

static void DriverVariableName(CHAR16 *name, UINT16 number) {
  static const CHAR16 hex[] = L"0123456789ABCDEF";
  memcpy(name, L"Driver", 6 * sizeof(CHAR16));
  for (int i = 0; i < 4; i++) name[6 + i] = hex[(number >> (12 - 4 * i)) & 0xf];
  name[10] = 0;
}

static BOOLEAN ReferencesDriverPath(const UINT8 *option, UINTN size) {
  UINTN pathSize = StrSize(DriverPath) - sizeof(CHAR16);
  for (UINTN i = 0; i + pathSize <= size; i += 2) {
    if (MemEqual(option + i, DriverPath, pathSize)) return TRUE;
  }
  return FALSE;
}

// Reads a variable into a pool allocation, which the caller frees
static EFI_STATUS ReadVariable(EFI_RUNTIME_SERVICES *rt, CHAR16 *name, VOID **data, UINTN *size) {
  *size = 0;
  EFI_STATUS status = rt->GetVariable(name, &GlobalVariableGuid, NULL, size, NULL);
  if (status != EFI_BUFFER_TOO_SMALL) return EFI_ERROR(status) ? status : EFI_NOT_FOUND;

  status = BS->AllocatePool(EfiBootServicesData, *size, data);
  if (EFI_ERROR(status)) return status;

  status = rt->GetVariable(name, &GlobalVariableGuid, NULL, size, *data);
  if (EFI_ERROR(status)) BS->FreePool(*data);
  return status;
}

static BOOLEAN IsRegistered(EFI_RUNTIME_SERVICES *rt, const UINT16 *order, UINTN count) {
  for (UINTN i = 0; i < count; i++) {
    CHAR16 name[11];
    VOID *option;
    UINTN size;

    DriverVariableName(name, order[i]);
    if (EFI_ERROR(ReadVariable(rt, name, &option, &size))) continue;

    BOOLEAN registered = ReferencesDriverPath(option, size);
    BS->FreePool(option);
    if (registered) return TRUE;
  }
  return FALSE;
}

// Adds a Driver#### option pointing to DriverPath (a bare file path device path, which the firmware
// expands by searching every file system) to the end of DriverOrder, unless one exists already.
static void RegisterDriverOption(EFI_RUNTIME_SERVICES *rt) {
  UINT16 *order = NULL;
  UINTN orderSize = 0;
  if (EFI_ERROR(ReadVariable(rt, L"DriverOrder", (VOID **)&order, &orderSize))) {
    order = NULL;
    orderSize = 0;
  }
  UINTN count = orderSize / sizeof(UINT16);

  if (IsRegistered(rt, order, count)) {
    if (order) BS->FreePool(order);
    return;
  }

  // The first Driver#### that isn't taken, whether it's in DriverOrder or not
  CHAR16 name[11];
  UINT32 number = 0;
  for (; number <= 0xFFFF; number++) {
    UINTN size = 0;
    DriverVariableName(name, (UINT16)number);
    if (rt->GetVariable(name, &GlobalVariableGuid, NULL, &size, NULL) == EFI_NOT_FOUND) break;
  }
  if (number > 0xFFFF) {
    if (order) BS->FreePool(order);
    return;
  }

  // EFI_LOAD_OPTION: attributes, file path list length, description, then the file path list
  UINT8 option[4 + 2 + sizeof(DriverDescription) + sizeof(EFI_DEVICE_PATH_PROTOCOL) + sizeof(DriverPath) +
               sizeof(EFI_DEVICE_PATH_PROTOCOL)];
  UINT32 attributes = LOAD_OPTION_ACTIVE;
  UINT16 pathListLength = (UINT16)(sizeof(EFI_DEVICE_PATH_PROTOCOL) + sizeof(DriverPath) + sizeof(EFI_DEVICE_PATH_PROTOCOL));
  UINT8 *p = option;

  memcpy(p, &attributes, 4);
  p += 4;
  memcpy(p, &pathListLength, 2);
  p += 2;
  memcpy(p, DriverDescription, sizeof(DriverDescription));
  p += sizeof(DriverDescription);

  EFI_DEVICE_PATH_PROTOCOL *file = (EFI_DEVICE_PATH_PROTOCOL *)p;
  UINT16 fileNodeLength = (UINT16)(sizeof(EFI_DEVICE_PATH_PROTOCOL) + sizeof(DriverPath));
  file->Type = MEDIA_DEVICE_PATH;
  file->SubType = MEDIA_FILEPATH_DP;
  memcpy(file->Length, &fileNodeLength, 2);
  memcpy(p + sizeof(EFI_DEVICE_PATH_PROTOCOL), DriverPath, sizeof(DriverPath));
  p += fileNodeLength;

  EFI_DEVICE_PATH_PROTOCOL *end = (EFI_DEVICE_PATH_PROTOCOL *)p;
  end->Type = END_DEVICE_PATH_TYPE;
  end->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  end->Length[0] = sizeof(EFI_DEVICE_PATH_PROTOCOL);
  end->Length[1] = 0;

  UINT32 variableAttributes = EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
  UINT16 *newOrder;
  if (!EFI_ERROR(rt->SetVariable(name, &GlobalVariableGuid, variableAttributes, sizeof(option), option)) &&
      !EFI_ERROR(BS->AllocatePool(EfiBootServicesData, orderSize + sizeof(UINT16), (VOID **)&newOrder))) {
    memcpy(newOrder, order, orderSize);
    newOrder[count] = (UINT16)number;
    rt->SetVariable(L"DriverOrder", &GlobalVariableGuid, variableAttributes, orderSize + sizeof(UINT16), newOrder);
    BS->FreePool(newOrder);
  }

  if (order) BS->FreePool(order);
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systemTable) {
  BS = systemTable->BootServices;

  VOID *resident;
  if (!EFI_ERROR(BS->LocateProtocol(&ResidentProtocolGuid, NULL, &resident))) {
    RegisterDriverOption(systemTable->RuntimeServices);
    return EFI_ALREADY_STARTED;
  }

  EFI_STATUS status = BS->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, Flush, NULL, &FlushTimer);
  if (EFI_ERROR(status)) return status;

  EFI_EVENT exitBootServices;
  BS->CreateEventEx(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, StopFlushing, NULL, &ExitBootServicesEventGroup, &exitBootServices);

  // When loaded as a Driver#### option, the GOPs don't exist yet
  EFI_HANDLE *handles;
  UINTN count;
  if (!EFI_ERROR(BS->LocateHandleBuffer(ByProtocol, &GraphicsOutputProtocolGuid, NULL, &count, &handles))) {
    for (UINTN i = 0; i < count; i++) Adopt(handles[i]);
    BS->FreePool(handles);
  }

  EFI_EVENT gopInstalled;
  if (!EFI_ERROR(BS->CreateEvent(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, AdoptNewGops, NULL, &gopInstalled))) {
    BS->RegisterProtocolNotify(&GraphicsOutputProtocolGuid, gopInstalled, &GopRegistration);
  }

  EFI_HANDLE residentHandle = NULL;
  BS->InstallProtocolInterface(&residentHandle, &ResidentProtocolGuid, 0, NULL);

  RegisterDriverOption(systemTable->RuntimeServices);

  return EFI_SUCCESS;
}
