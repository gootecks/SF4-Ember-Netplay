#define DIRECTINPUT_VERSION 0x0800
#define INITGUID
#include <dinput.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include <xinput.h>

#define MAX_DI 8

static LPDIRECTINPUT8A di;
static LPDIRECTINPUTDEVICE8A dev[MAX_DI];
static int devCount;
static HWND wnd;

static BOOL CALLBACK OnDevice(LPCDIDEVICEINSTANCEA inst, LPVOID ctx) {
  (void)ctx;
  DWORD vid = LOWORD(inst->guidProduct.Data1),
        pid = HIWORD(inst->guidProduct.Data1);
  printf("dinput: [%d] \"%s\" vid=%04lx pid=%04lx type=0x%02lx\n", devCount,
         inst->tszProductName, vid, pid,
         (unsigned long)GET_DIDEVICE_TYPE(inst->dwDevType));
  if (devCount >= MAX_DI)
    return DIENUM_STOP;
  LPDIRECTINPUTDEVICE8A d;
  if (FAILED(IDirectInput8_CreateDevice(di, &inst->guidInstance, &d, NULL)))
    return DIENUM_CONTINUE;
  if (FAILED(IDirectInputDevice8_SetDataFormat(d, &c_dfDIJoystick2)) ||
      FAILED(IDirectInputDevice8_SetCooperativeLevel(
          d, wnd, DISCL_BACKGROUND | DISCL_NONEXCLUSIVE)) ||
      FAILED(IDirectInputDevice8_Acquire(d))) {
    printf("dinput: [%d] could not acquire\n", devCount);
    IDirectInputDevice8_Release(d);
    return DIENUM_CONTINUE;
  }
  dev[devCount] = d;
  devCount++;
  return DIENUM_CONTINUE;
}

static void PrintXButtons(WORD b) {
  static const struct {
    WORD bit;
    const char *name;
  } map[] = {{XINPUT_GAMEPAD_DPAD_UP, "Up"},
             {XINPUT_GAMEPAD_DPAD_DOWN, "Down"},
             {XINPUT_GAMEPAD_DPAD_LEFT, "Left"},
             {XINPUT_GAMEPAD_DPAD_RIGHT, "Right"},
             {XINPUT_GAMEPAD_START, "Start"},
             {XINPUT_GAMEPAD_BACK, "Back"},
             {XINPUT_GAMEPAD_LEFT_THUMB, "LS"},
             {XINPUT_GAMEPAD_RIGHT_THUMB, "RS"},
             {XINPUT_GAMEPAD_LEFT_SHOULDER, "LB"},
             {XINPUT_GAMEPAD_RIGHT_SHOULDER, "RB"},
             {XINPUT_GAMEPAD_A, "A"},
             {XINPUT_GAMEPAD_B, "B"},
             {XINPUT_GAMEPAD_X, "X"},
             {XINPUT_GAMEPAD_Y, "Y"}};
  for (size_t i = 0; i < sizeof map / sizeof *map; i++)
    if (b & map[i].bit)
      printf(" %s", map[i].name);
}

int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 0;
  setvbuf(stdout, NULL, _IONBF, 0);
  wnd = CreateWindowA("STATIC", "Ember pad probe: press buttons here",
                      WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 480, 120,
                      NULL, NULL, GetModuleHandle(NULL), NULL);
  SetForegroundWindow(wnd);

  XINPUT_STATE xs[XUSER_MAX_COUNT];
  BOOL xon[XUSER_MAX_COUNT] = {0};
  for (DWORD i = 0; i < XUSER_MAX_COUNT; i++) {
    XINPUT_CAPABILITIES caps;
    DWORD r = XInputGetCapabilities(i, 0, &caps);
    if (r == ERROR_SUCCESS) {
      xon[i] = TRUE;
      XInputGetState(i, &xs[i]);
      printf("xinput: slot %lu connected type=%u subtype=%u\n", i, caps.Type,
             caps.SubType);
    } else {
      printf("xinput: slot %lu empty\n", i);
    }
  }

  if (FAILED(DirectInput8Create(GetModuleHandle(NULL), DIRECTINPUT_VERSION,
                                &IID_IDirectInput8A, (void **)&di, NULL))) {
    printf("dinput: DirectInput8Create failed\n");
  } else {
    IDirectInput8_EnumDevices(di, DI8DEVCLASS_GAMECTRL, OnDevice, NULL,
                              DIEDFL_ATTACHEDONLY);
    if (!devCount)
      printf("dinput: no game controllers\n");
  }

  DIJOYSTATE2 js[MAX_DI], prev[MAX_DI];
  memset(prev, 0, sizeof prev);
  for (int i = 0; i < devCount; i++) {
    IDirectInputDevice8_Poll(dev[i]);
    IDirectInputDevice8_GetDeviceState(dev[i], sizeof prev[i], &prev[i]);
  }

  DWORD end = GetTickCount() + (DWORD)seconds * 1000;
  if (seconds)
    printf("polling %d s: press every button and direction\n", seconds);
  while (seconds && GetTickCount() < end) {
    for (DWORD i = 0; i < XUSER_MAX_COUNT; i++) {
      if (!xon[i])
        continue;
      XINPUT_STATE s;
      if (XInputGetState(i, &s) != ERROR_SUCCESS ||
          s.dwPacketNumber == xs[i].dwPacketNumber)
        continue;
      XINPUT_GAMEPAD *g = &s.Gamepad, *o = &xs[i].Gamepad;
      if (g->wButtons != o->wButtons ||
          (g->bLeftTrigger > 128) != (o->bLeftTrigger > 128) ||
          (g->bRightTrigger > 128) != (o->bRightTrigger > 128) ||
          (g->sThumbLX / 16384) != (o->sThumbLX / 16384) ||
          (g->sThumbLY / 16384) != (o->sThumbLY / 16384)) {
        printf("%8lu xinput %lu:", GetTickCount(), i);
        PrintXButtons(g->wButtons);
        if (g->bLeftTrigger > 128)
          printf(" LT");
        if (g->bRightTrigger > 128)
          printf(" RT");
        printf(" lx=%d ly=%d\n", g->sThumbLX, g->sThumbLY);
      }
      xs[i] = s;
    }
    for (int i = 0; i < devCount; i++) {
      IDirectInputDevice8_Poll(dev[i]);
      if (FAILED(
              IDirectInputDevice8_GetDeviceState(dev[i], sizeof js[i], &js[i])))
        continue;
      if (memcmp(js[i].rgbButtons, prev[i].rgbButtons, 32) ||
          js[i].rgdwPOV[0] != prev[i].rgdwPOV[0] ||
          (js[i].lX / 16384) != (prev[i].lX / 16384) ||
          (js[i].lY / 16384) != (prev[i].lY / 16384)) {
        printf("%8lu dinput %d:", GetTickCount(), i);
        for (int b = 0; b < 32; b++)
          if (js[i].rgbButtons[b] & 0x80)
            printf(" b%d", b);
        if (LOWORD(js[i].rgdwPOV[0]) != 0xFFFF)
          printf(" pov=%lu", js[i].rgdwPOV[0] / 100);
        printf(" x=%ld y=%ld\n", js[i].lX, js[i].lY);
      }
      prev[i] = js[i];
    }
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
      DispatchMessageA(&msg);
    Sleep(4);
  }
  return 0;
}
