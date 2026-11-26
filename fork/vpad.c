/*
 * vpad.so: plugs a virtual game controller into the game, for the smoke test.
 *
 * Loaded with LD_PRELOAD into a client built with SDL2. On the game's first
 * SDL_PollEvent it attaches an SDL virtual joystick that SDL treats as an
 * Xbox 360 pad, so it arrives like a real one. Once the file VPAD_GO exists
 * it plays VPAD_SCRIPT, lines of
 *
 *   <ms> button <n> <0|1>     SDL_GameControllerButton n up or down
 *   <ms> axis <n> <value>     SDL_GameControllerAxis n, -32768 to 32767
 *
 * where ms counts from when VPAD_GO appeared. Needs SDL 2.24 or later.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <SDL.h>

static int (*real_poll)(SDL_Event *);
static SDL_Joystick *pad;
static FILE *script;
static Uint32 go;
static char line[256];
static int pending;

static void plug(void)
{
	SDL_VirtualJoystickDesc desc;
	int index;

	memset(&desc, 0, sizeof(desc));
	desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
	desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
	desc.naxes = SDL_CONTROLLER_AXIS_MAX;
	desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
	desc.vendor_id = 0x045e;
	desc.product_id = 0x028e;
	desc.name = "Virtual Test Pad";
	index = SDL_JoystickAttachVirtualEx(&desc);
	if (index < 0) {
		fprintf(stderr, "vpad: can't attach: %s\n", SDL_GetError());
		return;
	}
	pad = SDL_JoystickOpen(index);
}

static void play(void)
{
	const char *gofile = getenv("VPAD_GO");
	unsigned ms;
	char kind[16];
	int n, value;

	if (!go && gofile && access(gofile, F_OK) == 0)
		go = SDL_GetTicks();
	while (script && go) {
		if (!pending) {
			if (!fgets(line, sizeof(line), script)) {
				fclose(script);
				script = NULL;
				return;
			}
			pending = 1;
		}
		if (sscanf(line, "%u %15s %d %d", &ms, kind, &n, &value) != 4) {
			pending = 0;
			continue;
		}
		if (SDL_GetTicks() - go < ms)
			return;
		pending = 0;
		if (!strcmp(kind, "button"))
			SDL_JoystickSetVirtualButton(pad, n, (Uint8)value);
		else if (!strcmp(kind, "axis"))
			SDL_JoystickSetVirtualAxis(pad, n, (Sint16)value);
	}
}

int SDL_PollEvent(SDL_Event *event)
{
	static int started;

	if (!real_poll)
		real_poll = (int (*)(SDL_Event *))dlsym(RTLD_NEXT, "SDL_PollEvent");
	if (!started) {
		started = 1;
		plug();
		if (pad && getenv("VPAD_SCRIPT"))
			script = fopen(getenv("VPAD_SCRIPT"), "r");
	}
	play();
	return real_poll(event);
}
