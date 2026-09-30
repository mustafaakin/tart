// UEFI application that boots the Windows installation media: \EFI\BOOT\BOOTAA64.EFI on its EFI system
// partition. It loads the framebuffer driver from the same partition, then starts Windows Boot Manager,
// which the media carries as \efi\boot\windows.efi so that the firmware never boots it on its own.

#include "efi.h"

static EFI_GUID LoadedImageProtocolGuid = {0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID DevicePathProtocolGuid = {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
static EFI_GUID SimpleFileSystemProtocolGuid = {0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};

static EFI_BOOT_SERVICES *BS;

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

static UINTN StrSize(const CHAR16 *s) {
  UINTN n = 0;
  while (s[n]) n++;
  return (n + 1) * sizeof(CHAR16);
}

static UINTN NodeLength(const EFI_DEVICE_PATH_PROTOCOL *node) {
  return node->Length[0] | (node->Length[1] << 8);
}

// Device path of a file on the given volume: the volume's device path, a file path node and an end node.
static EFI_DEVICE_PATH_PROTOCOL *FileDevicePath(EFI_HANDLE volume, const CHAR16 *path) {
  EFI_DEVICE_PATH_PROTOCOL *volumePath;
  if (EFI_ERROR(BS->HandleProtocol(volume, &DevicePathProtocolGuid, (VOID **)&volumePath))) return NULL;

  UINTN volumePathSize = 0;
  for (EFI_DEVICE_PATH_PROTOCOL *node = volumePath; node->Type != END_DEVICE_PATH_TYPE;
       node = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)node + NodeLength(node))) {
    volumePathSize += NodeLength(node);
  }

  UINTN pathSize = StrSize(path);
  UINT16 fileNodeLength = (UINT16)(sizeof(EFI_DEVICE_PATH_PROTOCOL) + pathSize);
  UINT8 *result;
  if (EFI_ERROR(BS->AllocatePool(EfiBootServicesData, volumePathSize + fileNodeLength + sizeof(EFI_DEVICE_PATH_PROTOCOL),
                                 (VOID **)&result))) {
    return NULL;
  }

  memcpy(result, volumePath, volumePathSize);

  EFI_DEVICE_PATH_PROTOCOL *file = (EFI_DEVICE_PATH_PROTOCOL *)(result + volumePathSize);
  file->Type = MEDIA_DEVICE_PATH;
  file->SubType = MEDIA_FILEPATH_DP;
  memcpy(file->Length, &fileNodeLength, 2);
  memcpy((UINT8 *)file + sizeof(EFI_DEVICE_PATH_PROTOCOL), path, pathSize);

  EFI_DEVICE_PATH_PROTOCOL *end = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)file + fileNodeLength);
  end->Type = END_DEVICE_PATH_TYPE;
  end->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  end->Length[0] = sizeof(EFI_DEVICE_PATH_PROTOCOL);
  end->Length[1] = 0;

  return (EFI_DEVICE_PATH_PROTOCOL *)result;
}

static EFI_STATUS Load(EFI_HANDLE parent, EFI_HANDLE volume, const CHAR16 *path, EFI_HANDLE *image) {
  EFI_DEVICE_PATH_PROTOCOL *devicePath = FileDevicePath(volume, path);
  if (!devicePath) return EFI_NOT_FOUND;

  EFI_STATUS status = BS->LoadImage(FALSE, parent, devicePath, NULL, 0, image);
  BS->FreePool(devicePath);
  return status;
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systemTable) {
  BS = systemTable->BootServices;

  EFI_LOADED_IMAGE_PROTOCOL *loadedImage;
  if (EFI_ERROR(BS->HandleProtocol(image, &LoadedImageProtocolGuid, (VOID **)&loadedImage))) return EFI_LOAD_ERROR;

  // Already resident if the firmware loaded it as a Driver#### option; that's fine
  EFI_HANDLE driver;
  if (!EFI_ERROR(Load(image, loadedImage->DeviceHandle, L"\\EFI\\tart\\framebuffer.efi", &driver))) {
    BS->StartImage(driver, NULL, NULL);
  }

  EFI_HANDLE *volumes;
  UINTN count;
  EFI_STATUS status = BS->LocateHandleBuffer(ByProtocol, &SimpleFileSystemProtocolGuid, NULL, &count, &volumes);
  if (EFI_ERROR(status)) return status;

  for (UINTN i = 0; i < count; i++) {
    EFI_HANDLE bootManager;
    if (EFI_ERROR(Load(image, volumes[i], L"\\efi\\boot\\windows.efi", &bootManager))) continue;

    BS->FreePool(volumes);
    return BS->StartImage(bootManager, NULL, NULL);
  }

  BS->FreePool(volumes);
  return EFI_NOT_FOUND;
}
