/*
Copyright (C) 2026 The LinuxGroove team

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/

// in_pad.c -- game controllers through SDL2's GameController API
//
// SDL is used for input only: no SDL window, no change to the video code.
// Buttons and triggers become the PAD_ keys and go through Key_Event, so
// they bind like any other key. The left stick moves and the right stick
// looks, added straight into the move command. In menus the left stick and
// the d-pad send PAD_ arrows, which M_Keydown turns into the arrow keys.

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "client.h"
#include "in_pad.h"

#define SDL_MAIN_HANDLED
#include <SDL.h>

#define MAX_PADS		4
#define NUM_PAD_KEYS	(K_PAD_RT - K_PAD_A + 1)

// where a press of a pad key comes from; a key stays down while any pad
// holds it from any source
#define HOLD_BUTTON		1	// a button or a trigger
#define HOLD_STICK		2	// the left stick, in menus

#define REPEAT_DELAY	400	// ms before a held direction repeats in menus
#define REPEAT_RATE		100	// ms between repeats

typedef struct
{
	SDL_GameController	*controller;
	SDL_JoystickID		id;
	char				name[64];
	qboolean			trigger[2];	// LT and RT are pressed
	int					stick_key;	// direction the left stick holds in menus
} pad_t;

static pad_t		pads[MAX_PADS];
static int			active_pad = -1;	// the pad used last drives the player
static qboolean		pad_started;
static qboolean		pad_focused = true;
static unsigned		pad_held[NUM_PAD_KEYS];	// HOLD_ bits, two for each pad
static int			repeat_key;
static unsigned		repeat_time;

cvar_t	*in_gamepad;
cvar_t	*pad_sensitivity;
cvar_t	*pad_yawspeed;
cvar_t	*pad_pitchspeed;
cvar_t	*pad_invert;
cvar_t	*pad_lookexpo;
cvar_t	*pad_deadzone_move;
cvar_t	*pad_deadzone_look;
cvar_t	*pad_movesnap;
cvar_t	*pad_trigger;
cvar_t	*pad_debug;

extern cvar_t	*fov;

static const struct
{
	int		button;
	int		key;
} pad_buttons[] =
{
	{SDL_CONTROLLER_BUTTON_A,				K_PAD_A},
	{SDL_CONTROLLER_BUTTON_B,				K_PAD_B},
	{SDL_CONTROLLER_BUTTON_X,				K_PAD_X},
	{SDL_CONTROLLER_BUTTON_Y,				K_PAD_Y},
	{SDL_CONTROLLER_BUTTON_BACK,			K_PAD_BACK},
	{SDL_CONTROLLER_BUTTON_GUIDE,			K_PAD_GUIDE},
	{SDL_CONTROLLER_BUTTON_START,			K_PAD_START},
	{SDL_CONTROLLER_BUTTON_LEFTSTICK,		K_PAD_LSTICK},
	{SDL_CONTROLLER_BUTTON_RIGHTSTICK,		K_PAD_RSTICK},
	{SDL_CONTROLLER_BUTTON_LEFTSHOULDER,	K_PAD_LB},
	{SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,	K_PAD_RB},
	{SDL_CONTROLLER_BUTTON_DPAD_UP,			K_PAD_UP},
	{SDL_CONTROLLER_BUTTON_DPAD_DOWN,		K_PAD_DOWN},
	{SDL_CONTROLLER_BUTTON_DPAD_LEFT,		K_PAD_LEFT},
	{SDL_CONTROLLER_BUTTON_DPAD_RIGHT,		K_PAD_RIGHT},
#if SDL_VERSION_ATLEAST(2, 0, 14)
	{SDL_CONTROLLER_BUTTON_MISC1,			K_PAD_MISC},
	{SDL_CONTROLLER_BUTTON_PADDLE1,			K_PAD_PADDLE1},
	{SDL_CONTROLLER_BUTTON_PADDLE2,			K_PAD_PADDLE2},
	{SDL_CONTROLLER_BUTTON_PADDLE3,			K_PAD_PADDLE3},
	{SDL_CONTROLLER_BUTTON_PADDLE4,			K_PAD_PADDLE4},
	{SDL_CONTROLLER_BUTTON_TOUCHPAD,		K_PAD_TOUCHPAD},
#endif
};

#define NUM_PAD_BUTTONS (sizeof(pad_buttons) / sizeof(pad_buttons[0]))

/*
==============================================================================

PAD KEYS

==============================================================================
*/

/*
===========
Pad_Hold

Presses or lets go of a pad key for one source on one pad. Key_Event hears
about it only when the first source presses the key or the last one lets go,
so the d-pad and the stick, or two pads, can't leave a key stuck down.
===========
*/
static void Pad_Hold (int slot, int key, int source, qboolean down)
{
	unsigned	bit, was, now;
	unsigned	time;

	bit = (unsigned)source << (slot * 2);
	was = pad_held[key - K_PAD_A];
	now = down ? (was | bit) : (was & ~bit);
	pad_held[key - K_PAD_A] = now;

	time = (unsigned)Sys_Milliseconds ();
	if (!was && now)
	{
		Key_Event (key, true, time);
		if (key >= K_PAD_UP && key <= K_PAD_RIGHT)
		{
			repeat_key = key;
			repeat_time = time + REPEAT_DELAY;
		}
	}
	else if (was && !now)
	{
		Key_Event (key, false, time);
		if (key == repeat_key)
			repeat_key = 0;
	}
}

// lets go of every key one pad holds
static void Pad_Release (int slot)
{
	int		key;

	for (key = K_PAD_A; key <= K_PAD_RT; key++)
	{
		Pad_Hold (slot, key, HOLD_BUTTON, false);
		Pad_Hold (slot, key, HOLD_STICK, false);
	}
	pads[slot].trigger[0] = pads[slot].trigger[1] = false;
	pads[slot].stick_key = 0;
}

static void Pad_ReleaseAll (void)
{
	int		slot;

	for (slot = 0; slot < MAX_PADS; slot++)
		if (pads[slot].controller)
			Pad_Release (slot);
}

/*
===========
Pad_Repeat

Repeats a held direction in menus. Key_Event ignores a second press without
a release, so each repeat is a release and a press.
===========
*/
static void Pad_Repeat (void)
{
	unsigned	time;

	if (!repeat_key)
		return;

	time = (unsigned)Sys_Milliseconds ();
	if (cls.key_dest != key_menu)
	{
		repeat_time = time + REPEAT_DELAY;
		return;
	}
	if ((int)(time - repeat_time) < 0)
		return;

	repeat_time = time + REPEAT_RATE;
	Key_Event (repeat_key, false, time);
	Key_Event (repeat_key, true, time);
}

/*
==============================================================================

STICKS AND TRIGGERS

==============================================================================
*/

static float Pad_Axis (SDL_GameController *controller, SDL_GameControllerAxis axis)
{
	return SDL_GameControllerGetAxis (controller, axis) / 32767.0f;
}

/*
===========
Pad_Stick

Reads a stick with a radial deadzone: nothing inside it, then from zero at
its edge up to a length of one at full tilt.
===========
*/
static void Pad_Stick (SDL_GameController *controller, SDL_GameControllerAxis ax,
	SDL_GameControllerAxis ay, float deadzone, float *x, float *y)
{
	float	length, scale;

	*x = Pad_Axis (controller, ax);
	*y = Pad_Axis (controller, ay);

	if (deadzone < 0)
		deadzone = 0;
	else if (deadzone > 0.9f)
		deadzone = 0.9f;

	length = sqrt (*x * *x + *y * *y);
	if (length <= deadzone)
	{
		*x = *y = 0;
		return;
	}

	scale = (length - deadzone) / (1 - deadzone);
	if (scale > 1)
		scale = 1;
	scale /= length;
	*x *= scale;
	*y *= scale;
}

// presses LT and RT past pad_trigger, and lets go below three quarters of it
static void Pad_Triggers (int slot)
{
	static const SDL_GameControllerAxis axes[2] =
		{SDL_CONTROLLER_AXIS_TRIGGERLEFT, SDL_CONTROLLER_AXIS_TRIGGERRIGHT};
	static const int keys[2] = {K_PAD_LT, K_PAD_RT};
	pad_t	*pad = &pads[slot];
	float	press, value;
	int		i;

	press = pad_trigger->value;
	if (press < 0.05f)
		press = 0.05f;
	else if (press > 0.95f)
		press = 0.95f;

	for (i = 0; i < 2; i++)
	{
		value = Pad_Axis (pad->controller, axes[i]);
		if (!pad->trigger[i] && value >= press)
		{
			pad->trigger[i] = true;
			active_pad = slot;
			Pad_Hold (slot, keys[i], HOLD_BUTTON, true);
		}
		else if (pad->trigger[i] && value < press * 0.75f)
		{
			pad->trigger[i] = false;
			Pad_Hold (slot, keys[i], HOLD_BUTTON, false);
		}
	}
}

// how far the stick leans towards a direction key
static float Pad_Towards (int key, float x, float y)
{
	switch (key)
	{
	case K_PAD_UP:		return -y;
	case K_PAD_DOWN:	return y;
	case K_PAD_LEFT:	return -x;
	case K_PAD_RIGHT:	return x;
	}
	return 0;
}

/*
===========
Pad_MenuStick

In menus the left stick holds PAD_UP, PAD_DOWN, PAD_LEFT or PAD_RIGHT once it
is past half way, until it comes back under 0.4.
===========
*/
static void Pad_MenuStick (int slot)
{
	pad_t	*pad = &pads[slot];
	float	x, y;
	int		key = 0;

	if (cls.key_dest == key_menu)
	{
		x = Pad_Axis (pad->controller, SDL_CONTROLLER_AXIS_LEFTX);
		y = Pad_Axis (pad->controller, SDL_CONTROLLER_AXIS_LEFTY);

		if (pad->stick_key && Pad_Towards (pad->stick_key, x, y) > 0.4f)
			key = pad->stick_key;
		else if (fabs (x) > fabs (y) && fabs (x) > 0.5f)
			key = x > 0 ? K_PAD_RIGHT : K_PAD_LEFT;
		else if (fabs (y) > 0.5f)
			key = y > 0 ? K_PAD_DOWN : K_PAD_UP;
	}

	if (key == pad->stick_key)
		return;

	if (pad->stick_key)
		Pad_Hold (slot, pad->stick_key, HOLD_STICK, false);
	pad->stick_key = key;
	if (key)
	{
		active_pad = slot;
		Pad_Hold (slot, key, HOLD_STICK, true);
	}
}

// a pad whose sticks move well past the deadzone takes over the player
static void Pad_CheckActive (int slot)
{
	SDL_GameController	*c = pads[slot].controller;
	float				x, y;

	if (slot == active_pad)
		return;

	Pad_Stick (c, SDL_CONTROLLER_AXIS_LEFTX, SDL_CONTROLLER_AXIS_LEFTY, 0.5f, &x, &y);
	if (x || y)
	{
		active_pad = slot;
		return;
	}
	Pad_Stick (c, SDL_CONTROLLER_AXIS_RIGHTX, SDL_CONTROLLER_AXIS_RIGHTY, 0.5f, &x, &y);
	if (x || y)
		active_pad = slot;
}

/*
==============================================================================

CONNECTING

==============================================================================
*/

static int Pad_Slot (SDL_JoystickID id)
{
	int		slot;

	for (slot = 0; slot < MAX_PADS; slot++)
		if (pads[slot].controller && pads[slot].id == id)
			return slot;
	return -1;
}

static void Pad_Open (int index)
{
	SDL_GameController	*controller;
	SDL_JoystickID		id;
	const char			*name;
	int					slot;

	if (!SDL_IsGameController (index))
		return;

	controller = SDL_GameControllerOpen (index);
	if (!controller)
	{
		Com_Printf ("Couldn't open controller %d: %s\n", index, SDL_GetError ());
		return;
	}
	id = SDL_JoystickInstanceID (SDL_GameControllerGetJoystick (controller));
	name = SDL_GameControllerName (controller);
	if (!name)
		name = "unknown controller";

	if (Pad_Slot (id) != -1)
	{	// already open
		SDL_GameControllerClose (controller);
		return;
	}

	for (slot = 0; slot < MAX_PADS; slot++)
		if (!pads[slot].controller)
			break;
	if (slot == MAX_PADS)
	{
		Com_Printf ("Controller ignored, %d are connected already: %s\n", MAX_PADS, name);
		SDL_GameControllerClose (controller);
		return;
	}

	memset (&pads[slot], 0, sizeof(pads[slot]));
	pads[slot].controller = controller;
	pads[slot].id = id;
	Q_strncpyz2 (pads[slot].name, name, sizeof(pads[slot].name));
	if (active_pad == -1)
		active_pad = slot;

	Com_Printf ("Controller connected: %s\n", pads[slot].name);
}

static void Pad_Close (int slot)
{
	int		i;

	if (slot == -1)
		return;

	Pad_Release (slot);
	Com_Printf ("Controller disconnected: %s\n", pads[slot].name);
	SDL_GameControllerClose (pads[slot].controller);
	pads[slot].controller = NULL;

	if (active_pad == slot)
	{
		active_pad = -1;
		for (i = 0; i < MAX_PADS; i++)
		{
			if (pads[i].controller)
			{
				active_pad = i;
				break;
			}
		}
	}
}

static void Pad_Button (const SDL_ControllerButtonEvent *event)
{
	int			slot;
	unsigned	i;
	qboolean	down = event->state == SDL_PRESSED;

	slot = Pad_Slot (event->which);
	if (slot == -1)
		return;
	if (down && (!in_gamepad->integer || !pad_focused))
		return;

	for (i = 0; i < NUM_PAD_BUTTONS; i++)
	{
		if (pad_buttons[i].button == event->button)
		{
			if (down)
				active_pad = slot;
			Pad_Hold (slot, pad_buttons[i].key, HOLD_BUTTON, down);
			return;
		}
	}
}

/*
==============================================================================

ENGINE INTERFACE

==============================================================================
*/

void IN_Pad_Init (void)
{
	char	path[MAX_OSPATH];
	int		mappings;

	in_gamepad = Cvar_Get ("in_gamepad", "1", CVAR_ARCHIVE | CVARDOC_BOOL);
	Cvar_Describe (in_gamepad, "use game controllers.");
	pad_sensitivity = Cvar_Get ("pad_sensitivity", "1", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_sensitivity, "controller look speed multiplier.");
	pad_yawspeed = Cvar_Get ("pad_yawspeed", "220", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_yawspeed, "degrees per second the right stick turns at full tilt.");
	pad_pitchspeed = Cvar_Get ("pad_pitchspeed", "160", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_pitchspeed, "degrees per second the right stick looks up or down at full tilt.");
	pad_invert = Cvar_Get ("pad_invert", "0", CVAR_ARCHIVE | CVARDOC_BOOL);
	Cvar_Describe (pad_invert, "invert looking up and down with the right stick.");
	pad_lookexpo = Cvar_Get ("pad_lookexpo", "2", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_lookexpo, "right stick response curve: 1 is linear, higher aims more finely near the middle.");
	pad_deadzone_move = Cvar_Get ("pad_deadzone_move", "0.20", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_deadzone_move, "left stick deadzone, from 0 to 0.9.");
	pad_deadzone_look = Cvar_Get ("pad_deadzone_look", "0.15", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_deadzone_look, "right stick deadzone, from 0 to 0.9.");
	pad_movesnap = Cvar_Get ("pad_movesnap", "0.25", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_movesnap, "move straight along one axis when the left stick's other axis is this small in comparison, so dodges work.");
	pad_trigger = Cvar_Get ("pad_trigger", "0.30", CVAR_ARCHIVE | CVARDOC_FLOAT);
	Cvar_Describe (pad_trigger, "how far a trigger goes down before it counts as pressed.");
	pad_debug = Cvar_Get ("pad_debug", "0", CVARDOC_BOOL);
	Cvar_Describe (pad_debug, "print the sticks and the moves they make.");

	if (pad_started)
		return;

	SDL_SetHint (SDL_HINT_NO_SIGNAL_HANDLERS, "1");
	// there is no SDL window, so the game decides itself when it has focus
	SDL_SetHint (SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
#ifdef SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS
	// PAD_A is the bottom face button on every pad, Nintendo's too
	SDL_SetHint (SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0");
#endif

	if (SDL_InitSubSystem (SDL_INIT_GAMECONTROLLER) != 0)
	{
		Com_Printf ("Game controllers unavailable: %s\n", SDL_GetError ());
		return;
	}
	pad_started = true;

	// players can add mappings for unusual pads without a new build
	Com_sprintf (path, sizeof(path), "%s/gamecontrollerdb.txt", FS_Gamedir ());
	mappings = SDL_GameControllerAddMappingsFromFile (path);
	if (mappings > 0)
		Com_Printf ("Loaded %d controller mappings from %s\n", mappings, path);

	// pads plugged in already arrive as SDL_CONTROLLERDEVICEADDED events too
}

void IN_Pad_Shutdown (void)
{
	int		slot;

	if (!pad_started)
		return;

	for (slot = 0; slot < MAX_PADS; slot++)
		if (pads[slot].controller)
			SDL_GameControllerClose (pads[slot].controller);
	memset (pads, 0, sizeof(pads));
	memset (pad_held, 0, sizeof(pad_held));
	active_pad = -1;
	repeat_key = 0;

	SDL_QuitSubSystem (SDL_INIT_GAMECONTROLLER);
	pad_started = false;
}

void IN_Pad_Focus (qboolean focused)
{
	if (pad_debug && pad_debug->integer && focused != pad_focused)
		Com_Printf ("pad: window %s the focus\n", focused ? "has" : "lost");
	pad_focused = focused;
	if (!focused && pad_started)
		Pad_ReleaseAll ();
}

void IN_Pad_Commands (void)
{
	SDL_Event	event;
	int			slot;

	if (!pad_started)
		return;

	while (SDL_PollEvent (&event))
	{
		switch (event.type)
		{
		case SDL_CONTROLLERDEVICEADDED:
			Pad_Open (event.cdevice.which);
			break;
		case SDL_CONTROLLERDEVICEREMOVED:
			Pad_Close (Pad_Slot (event.cdevice.which));
			break;
		case SDL_CONTROLLERBUTTONDOWN:
		case SDL_CONTROLLERBUTTONUP:
			Pad_Button (&event.cbutton);
			break;
		}
	}

	if (!in_gamepad->integer || !pad_focused)
	{
		Pad_ReleaseAll ();
		return;
	}

	for (slot = 0; slot < MAX_PADS; slot++)
	{
		if (!pads[slot].controller)
			continue;
		Pad_Triggers (slot);
		Pad_MenuStick (slot);
		Pad_CheckActive (slot);
	}
	Pad_Repeat ();
}

void IN_Pad_Move (usercmd_t *cmd)
{
	SDL_GameController	*controller;
	float				mx, my, lx, ly;
	float				length, run, zoom, look;

	if (!pad_started || active_pad == -1 || !in_gamepad->integer
		|| !pad_focused || cls.key_dest != key_game)
		return;

	controller = pads[active_pad].controller;

	// move: analog speed up to the keyboard's, snapped to one axis when the
	// other is small, so running straight sends exactly no sideways move
	Pad_Stick (controller, SDL_CONTROLLER_AXIS_LEFTX, SDL_CONTROLLER_AXIS_LEFTY,
		pad_deadzone_move->value, &mx, &my);
	if (fabs (mx) < fabs (my) * pad_movesnap->value)
		mx = 0;
	else if (fabs (my) < fabs (mx) * pad_movesnap->value)
		my = 0;

	run = 1;
	if (!cl.tactical && ((in_speed.state & 1) ^ cl_run->integer))
		run = 2;
	cmd->forwardmove += (short)(-my * cl_forwardspeed->value * run);
	cmd->sidemove += (short)(mx * cl_sidespeed->value * run);

	// look: degrees per second, on a curve, slowed by zoom like the mouse
	Pad_Stick (controller, SDL_CONTROLLER_AXIS_RIGHTX, SDL_CONTROLLER_AXIS_RIGHTY,
		pad_deadzone_look->value, &lx, &ly);
	length = sqrt (lx * lx + ly * ly);
	if (length > 0 && pad_lookexpo->value > 0)
	{
		length = pow (length, pad_lookexpo->value) / length;
		lx *= length;
		ly *= length;
	}
	if (pad_invert->integer)
		ly = -ly;

	zoom = 1;
	if (fov->value > 0 && cl.refdef.fov_x > 0)
		zoom = cl.refdef.fov_x / fov->value;
	look = pad_sensitivity->value * zoom * cls.frametime;

	cl.viewangles[YAW] -= lx * pad_yawspeed->value * look;
	cl.viewangles[PITCH] += ly * pad_pitchspeed->value * look;

	if (pad_debug->integer && (mx || my || lx || ly))
		Com_Printf ("pad: move %.2f %.2f look %.2f %.2f, forward %d side %d in %.0f ms\n",
			mx, 0.0f - my, lx, 0.0f - ly, cmd->forwardmove, cmd->sidemove, cls.frametime * 1000);
}
