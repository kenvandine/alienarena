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

// in_pad.h -- game controllers through SDL2

#ifndef IN_PAD_H
#define IN_PAD_H

void IN_Pad_Init (void);
void IN_Pad_Shutdown (void);

// once per rendered frame: buttons, triggers, hotplug and menu repeat
void IN_Pad_Commands (void);

// once per command: the sticks
void IN_Pad_Move (usercmd_t *cmd);

// the game window gained or lost the keyboard focus
void IN_Pad_Focus (qboolean focused);

#endif
