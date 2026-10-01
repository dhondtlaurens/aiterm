# scripts/dmg-settings.py — dmgbuild's layout for AiTerm's release image: the app on the left, a
# link to /Applications on the right, nothing else. make-dmg.sh passes the app as `-D app=<path>`.
import os.path

app = defines["app"]  # noqa: F821 — dmgbuild provides `defines`
name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = [name]

default_view = "icon-view"
window_rect = ((200, 120), (540, 360))
icon_size = 128
text_size = 13
icon_locations = {name: (140, 170), "Applications": (400, 170)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
