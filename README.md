***********************************************************************************************

       Century-64 is a 64-bit Hobby Operating System written mostly in assembly.
       Copyright (C) 2014  Adam Scott Clark

       This program is free software: you can redistribute it and/or modify
       it under the terms of the GNU General Public License as published by
       the Free Software Foundation, either version 3 of the License, or
       any later version.

       This program is distributed in the hope that it will be useful,
       but WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
       GNU General Public License for more details.

       You should have received a copy of the GNU General Public License along
       with this program.  If not, see http://www.gnu.org/licenses/gpl-3.0-standalone.html.

***********************************************************************************************

Currently, Century-64 is in its infancy.  It has limited functionality and no user interface.

However, I hope Century-64 to be feature-rich.  The current capability is as follows:
* Long mode support (64-bit addressing [see note 1])
* Support for 256TB physical memory
* Support for 256TB virtual memory
* Support for 16TB kernel heap

Note 1: Current CPU limitations are 48-bit addresses.
