================================================================================
                         ZigPod Community Themes
================================================================================

Welcome! This folder contains custom themes for your ZigPod.

HOW TO USE
----------
1. Copy any .THM file to your iPod's /themes/ folder
2. Go to Settings > Theme and select your theme
3. Enjoy!


HOW TO CREATE YOUR OWN THEME
----------------------------
1. Copy an existing .THM file and rename it (8.3 format, e.g., MYTHEME.THM)
2. Open it in any text editor (Notepad, TextEdit, etc.)
3. Edit the colors using RGB values (0-255 for each: Red, Green, Blue)
4. Save and copy to your iPod's /themes/ folder

Theme File Format:

    [theme]
    name=Your Theme Name
    author=Your Name

    [colors]
    background=R,G,B       ; Main background color
    foreground=R,G,B       ; Main text color
    header_bg=R,G,B        ; Top bar background
    header_fg=R,G,B        ; Top bar text
    selected_bg=R,G,B      ; Highlighted item background
    selected_fg=R,G,B      ; Highlighted item text
    footer_bg=R,G,B        ; Bottom bar background
    footer_fg=R,G,B        ; Bottom bar text
    accent=R,G,B           ; Progress bars, icons
    disabled=R,G,B         ; Inactive/grayed out items


COLOR REFERENCE
---------------
RGB values range from 0 to 255 for each component.

Common colors:
  Black       = 0,0,0
  White       = 255,255,255
  Red         = 255,0,0
  Green       = 0,255,0
  Blue        = 0,0,255
  Yellow      = 255,255,0
  Cyan        = 0,255,255
  Magenta     = 255,0,255
  Orange      = 255,165,0
  Purple      = 128,0,128
  Gray        = 128,128,128
  Light Gray  = 192,192,192
  Dark Gray   = 64,64,64


TIPS
----
- Lines starting with ; are comments (ignored)
- Use online color pickers to find RGB values
- Test readability - make sure text contrasts with backgrounds
- Keep file size under 1KB
- Use 8.3 filenames (max 8 chars + .THM)


INCLUDED THEMES
---------------
RETRO.THM     - Classic green terminal style
CONTRAST.THM  - High contrast for accessibility
OCEAN.THM     - Calm blue tones
SUNSET.THM    - Warm orange and purple
MONO.THM      - Clean grayscale
COFFEE.THM    - Cozy brown tones
NORD.THM      - Arctic blue palette
SOLARIZE.THM  - Solarized dark scheme


SHARE YOUR THEMES
-----------------
Created something cool? Share it with the community!
https://github.com/[project]/zigpod

================================================================================
