# dmgbuild layout for Paluku (https://dmgbuild.readthedocs.io). Driven by scripts/package.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=<Paluku.app> -D background=<bg.tiff> [-D help=<link.webloc>] "Paluku X.Y.Z" out.dmg
# Icon centres must match scripts/make-dmg-background.swift (arrow between them). `help` is set for unsigned builds.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
help_link = defines.get("help")  # noqa: F821
files = [app] + ([help_link] if help_link else [])
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 480 if help_link else 400))
icon_size = 100
text_size = 13
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_locations = {os.path.basename(app): (170, 190), "Applications": (470, 190)}
if help_link:
    icon_locations[os.path.basename(help_link)] = (320, 390)
