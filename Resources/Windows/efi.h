// Minimal freestanding UEFI definitions for the AArch64 drivers in this directory.

#ifndef EFI_H
#define EFI_H

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef unsigned long long UINTN;
typedef long long INTN;
typedef unsigned short CHAR16;
typedef unsigned char BOOLEAN;
typedef void VOID;

#define EFIAPI
#define TRUE 1
#define FALSE 0
#define NULL ((void *)0)

typedef UINTN EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef VOID *EFI_EVENT;
typedef UINT64 EFI_PHYSICAL_ADDRESS;
typedef UINTN EFI_TPL;

#define EFI_PAGE_SIZE 4096
#define EFI_SIZE_TO_PAGES(size) (((size) + EFI_PAGE_SIZE - 1) / EFI_PAGE_SIZE)

#define EFIERR(a) ((1ULL << 63) | (a))
#define EFI_ERROR(status) (((INTN)(status)) < 0)
#define EFI_SUCCESS 0
#define EFI_LOAD_ERROR EFIERR(1)
#define EFI_INVALID_PARAMETER EFIERR(2)
#define EFI_UNSUPPORTED EFIERR(3)
#define EFI_BUFFER_TOO_SMALL EFIERR(5)
#define EFI_NOT_FOUND EFIERR(14)
#define EFI_ALREADY_STARTED EFIERR(20)

typedef struct {
  UINT32 Data1;
  UINT16 Data2;
  UINT16 Data3;
  UINT8 Data4[8];
} EFI_GUID;

typedef struct {
  UINT64 Signature;
  UINT32 Revision;
  UINT32 HeaderSize;
  UINT32 CRC32;
  UINT32 Reserved;
} EFI_TABLE_HEADER;

#define TPL_CALLBACK 8
#define EVT_TIMER 0x80000000
#define EVT_NOTIFY_SIGNAL 0x00000200

typedef enum { TimerCancel, TimerPeriodic, TimerRelative } EFI_TIMER_DELAY;
typedef enum { AllocateAnyPages, AllocateMaxAddress, AllocateAddress } EFI_ALLOCATE_TYPE;
typedef enum { AllHandles, ByRegisterNotify, ByProtocol } EFI_LOCATE_SEARCH_TYPE;
typedef enum {
  EfiReservedMemoryType,
  EfiLoaderCode,
  EfiLoaderData,
  EfiBootServicesCode,
  EfiBootServicesData,
} EFI_MEMORY_TYPE;

typedef VOID(EFIAPI *EFI_EVENT_NOTIFY)(EFI_EVENT Event, VOID *Context);

typedef struct {
  UINT8 Type;
  UINT8 SubType;
  UINT8 Length[2];
} EFI_DEVICE_PATH_PROTOCOL;

#define MEDIA_DEVICE_PATH 4
#define MEDIA_FILEPATH_DP 4
#define END_DEVICE_PATH_TYPE 0x7f
#define END_ENTIRE_DEVICE_PATH_SUBTYPE 0xff

// Graphics Output Protocol

typedef enum {
  PixelRedGreenBlueReserved8BitPerColor,
  PixelBlueGreenRedReserved8BitPerColor,
  PixelBitMask,
  PixelBltOnly,
} EFI_GRAPHICS_PIXEL_FORMAT;

typedef struct {
  UINT32 RedMask;
  UINT32 GreenMask;
  UINT32 BlueMask;
  UINT32 ReservedMask;
} EFI_PIXEL_BITMASK;

typedef struct {
  UINT32 Version;
  UINT32 HorizontalResolution;
  UINT32 VerticalResolution;
  EFI_GRAPHICS_PIXEL_FORMAT PixelFormat;
  EFI_PIXEL_BITMASK PixelInformation;
  UINT32 PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
  UINT32 MaxMode;
  UINT32 Mode;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
  UINTN SizeOfInfo;
  EFI_PHYSICAL_ADDRESS FrameBufferBase;
  UINTN FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
  UINT8 Blue;
  UINT8 Green;
  UINT8 Red;
  UINT8 Reserved;
} EFI_GRAPHICS_OUTPUT_BLT_PIXEL;

typedef enum {
  EfiBltVideoFill,
  EfiBltVideoToBltBuffer,
  EfiBltBufferToVideo,
  EfiBltVideoToVideo,
} EFI_GRAPHICS_OUTPUT_BLT_OPERATION;

struct EFI_GRAPHICS_OUTPUT_PROTOCOL;

typedef EFI_STATUS(EFIAPI *EFI_GOP_QUERY_MODE)(struct EFI_GRAPHICS_OUTPUT_PROTOCOL *This, UINT32 ModeNumber,
                                               UINTN *SizeOfInfo, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info);
typedef EFI_STATUS(EFIAPI *EFI_GOP_SET_MODE)(struct EFI_GRAPHICS_OUTPUT_PROTOCOL *This, UINT32 ModeNumber);
typedef EFI_STATUS(EFIAPI *EFI_GOP_BLT)(struct EFI_GRAPHICS_OUTPUT_PROTOCOL *This, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *BltBuffer,
                                        EFI_GRAPHICS_OUTPUT_BLT_OPERATION BltOperation, UINTN SourceX, UINTN SourceY,
                                        UINTN DestinationX, UINTN DestinationY, UINTN Width, UINTN Height, UINTN Delta);

typedef struct EFI_GRAPHICS_OUTPUT_PROTOCOL {
  EFI_GOP_QUERY_MODE QueryMode;
  EFI_GOP_SET_MODE SetMode;
  EFI_GOP_BLT Blt;
  EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
} EFI_GRAPHICS_OUTPUT_PROTOCOL;

// Boot and runtime services; members that aren't used are left untyped but keep their position.

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *RaiseTPL;
  VOID *RestoreTPL;
  EFI_STATUS(EFIAPI *AllocatePages)(EFI_ALLOCATE_TYPE, EFI_MEMORY_TYPE, UINTN, EFI_PHYSICAL_ADDRESS *);
  VOID *FreePages;
  VOID *GetMemoryMap;
  EFI_STATUS(EFIAPI *AllocatePool)(EFI_MEMORY_TYPE, UINTN, VOID **);
  EFI_STATUS(EFIAPI *FreePool)(VOID *);
  EFI_STATUS(EFIAPI *CreateEvent)(UINT32, EFI_TPL, EFI_EVENT_NOTIFY, VOID *, EFI_EVENT *);
  EFI_STATUS(EFIAPI *SetTimer)(EFI_EVENT, EFI_TIMER_DELAY, UINT64);
  VOID *WaitForEvent;
  VOID *SignalEvent;
  VOID *CloseEvent;
  VOID *CheckEvent;
  EFI_STATUS(EFIAPI *InstallProtocolInterface)(EFI_HANDLE *, EFI_GUID *, UINT32, VOID *);
  VOID *ReinstallProtocolInterface;
  VOID *UninstallProtocolInterface;
  EFI_STATUS(EFIAPI *HandleProtocol)(EFI_HANDLE, EFI_GUID *, VOID **);
  VOID *Reserved;
  EFI_STATUS(EFIAPI *RegisterProtocolNotify)(EFI_GUID *, EFI_EVENT, VOID **);
  VOID *LocateHandle;
  VOID *LocateDevicePath;
  VOID *InstallConfigurationTable;
  EFI_STATUS(EFIAPI *LoadImage)(BOOLEAN, EFI_HANDLE, EFI_DEVICE_PATH_PROTOCOL *, VOID *, UINTN, EFI_HANDLE *);
  EFI_STATUS(EFIAPI *StartImage)(EFI_HANDLE, UINTN *, CHAR16 **);
  VOID *Exit;
  VOID *UnloadImage;
  VOID *ExitBootServices;
  VOID *GetNextMonotonicCount;
  VOID *Stall;
  VOID *SetWatchdogTimer;
  VOID *ConnectController;
  VOID *DisconnectController;
  VOID *OpenProtocol;
  VOID *CloseProtocol;
  VOID *OpenProtocolInformation;
  VOID *ProtocolsPerHandle;
  EFI_STATUS(EFIAPI *LocateHandleBuffer)(EFI_LOCATE_SEARCH_TYPE, EFI_GUID *, VOID *, UINTN *, EFI_HANDLE **);
  EFI_STATUS(EFIAPI *LocateProtocol)(EFI_GUID *, VOID *, VOID **);
  VOID *InstallMultipleProtocolInterfaces;
  VOID *UninstallMultipleProtocolInterfaces;
  VOID *CalculateCrc32;
  VOID *CopyMem;
  VOID *SetMem;
  EFI_STATUS(EFIAPI *CreateEventEx)(UINT32, EFI_TPL, EFI_EVENT_NOTIFY, const VOID *, const EFI_GUID *, EFI_EVENT *);
} EFI_BOOT_SERVICES;

#define EFI_VARIABLE_NON_VOLATILE 0x1
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 0x2
#define EFI_VARIABLE_RUNTIME_ACCESS 0x4
#define LOAD_OPTION_ACTIVE 0x1

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *GetTime;
  VOID *SetTime;
  VOID *GetWakeupTime;
  VOID *SetWakeupTime;
  VOID *SetVirtualAddressMap;
  VOID *ConvertPointer;
  EFI_STATUS(EFIAPI *GetVariable)(CHAR16 *, EFI_GUID *, UINT32 *, UINTN *, VOID *);
  VOID *GetNextVariableName;
  EFI_STATUS(EFIAPI *SetVariable)(CHAR16 *, EFI_GUID *, UINT32, UINTN, VOID *);
} EFI_RUNTIME_SERVICES;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  UINT32 FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  VOID *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  VOID *ConOut;
  EFI_HANDLE StandardErrorHandle;
  VOID *StdErr;
  EFI_RUNTIME_SERVICES *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
} EFI_SYSTEM_TABLE;

typedef struct {
  UINT32 Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
} EFI_LOADED_IMAGE_PROTOCOL;

#endif
