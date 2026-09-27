/// Bundled identity seed (layer 1 of the layered index).
///
/// Hand-curated; incomplete by design. Every entry was verified by hand
/// against the backends' known package names — no scraping, no guessing.
/// See docs/architecture/phase3-identity-hld.md §4.4 and
/// docs/architecture/phase3-identity-lld.md §6.
///
/// The JSON is the source of truth; this constant is the vehicle (no
/// asset pipeline in a pure-Dart package).
const String kIdentitySeedJson = r'''{
  "schemaVersion": 1,
  "generatedAt": "2026-09-28T00:00:00Z",
  "source": "libreapp-center-seed",
  "entries": [
    {
      "canonicalId": "appstream:org.mozilla.firefox",
      "displayName": "Firefox",
      "appstreamIds": [
        "org.mozilla.firefox"
      ],
      "homepages": [
        "mozilla.org/firefox"
      ],
      "backends": {
        "snap": [
          "firefox"
        ],
        "deb": [
          "firefox"
        ],
        "flatpak": [
          "org.mozilla.firefox"
        ],
        "rpm": [
          "firefox"
        ],
        "pacman": [
          "firefox"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.mozilla.Thunderbird",
      "displayName": "Thunderbird",
      "appstreamIds": [
        "org.mozilla.Thunderbird"
      ],
      "homepages": [
        "mozilla.org/thunderbird"
      ],
      "backends": {
        "snap": [
          "thunderbird"
        ],
        "deb": [
          "thunderbird"
        ],
        "flatpak": [
          "org.mozilla.Thunderbird"
        ],
        "rpm": [
          "thunderbird"
        ],
        "pacman": [
          "thunderbird"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.chromium.Chromium",
      "displayName": "Chromium",
      "appstreamIds": [
        "org.chromium.Chromium"
      ],
      "homepages": [
        "chromium.org"
      ],
      "backends": {
        "snap": [
          "chromium"
        ],
        "deb": [
          "chromium"
        ],
        "flatpak": [
          "org.chromium.Chromium"
        ],
        "rpm": [
          "chromium"
        ],
        "pacman": [
          "chromium"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.videolan.VLC",
      "displayName": "VLC",
      "appstreamIds": [
        "org.videolan.VLC"
      ],
      "homepages": [
        "videolan.org/vlc"
      ],
      "backends": {
        "snap": [
          "vlc"
        ],
        "deb": [
          "vlc"
        ],
        "flatpak": [
          "org.videolan.VLC"
        ],
        "rpm": [
          "vlc"
        ],
        "pacman": [
          "vlc"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.gimp.GIMP",
      "displayName": "GIMP",
      "appstreamIds": [
        "org.gimp.GIMP"
      ],
      "homepages": [
        "gimp.org"
      ],
      "backends": {
        "snap": [
          "gimp"
        ],
        "deb": [
          "gimp"
        ],
        "flatpak": [
          "org.gimp.GIMP"
        ],
        "rpm": [
          "gimp"
        ],
        "pacman": [
          "gimp"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.inkscape.Inkscape",
      "displayName": "Inkscape",
      "appstreamIds": [
        "org.inkscape.Inkscape"
      ],
      "homepages": [
        "inkscape.org"
      ],
      "backends": {
        "snap": [
          "inkscape"
        ],
        "deb": [
          "inkscape"
        ],
        "flatpak": [
          "org.inkscape.Inkscape"
        ],
        "rpm": [
          "inkscape"
        ],
        "pacman": [
          "inkscape"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.blender.Blender",
      "displayName": "Blender",
      "appstreamIds": [
        "org.blender.Blender"
      ],
      "homepages": [
        "blender.org"
      ],
      "backends": {
        "snap": [
          "blender"
        ],
        "deb": [
          "blender"
        ],
        "flatpak": [
          "org.blender.Blender"
        ],
        "rpm": [
          "blender"
        ],
        "pacman": [
          "blender"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.kde.kdenlive",
      "displayName": "Kdenlive",
      "appstreamIds": [
        "org.kde.kdenlive"
      ],
      "homepages": [
        "kdenlive.org"
      ],
      "backends": {
        "snap": [
          "kdenlive"
        ],
        "deb": [
          "kdenlive"
        ],
        "flatpak": [
          "org.kde.kdenlive"
        ],
        "rpm": [
          "kdenlive"
        ],
        "pacman": [
          "kdenlive"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:com.obsproject.Studio",
      "displayName": "OBS Studio",
      "appstreamIds": [
        "com.obsproject.Studio"
      ],
      "homepages": [
        "obsproject.com"
      ],
      "backends": {
        "snap": [
          "obs-studio"
        ],
        "deb": [
          "obs-studio"
        ],
        "flatpak": [
          "com.obsproject.Studio"
        ],
        "rpm": [
          "obs-studio"
        ],
        "pacman": [
          "obs-studio"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.audacityteam.Audacity",
      "displayName": "Audacity",
      "appstreamIds": [
        "org.audacityteam.Audacity"
      ],
      "homepages": [
        "audacityteam.org"
      ],
      "backends": {
        "snap": [
          "audacity"
        ],
        "deb": [
          "audacity"
        ],
        "flatpak": [
          "org.audacityteam.Audacity"
        ],
        "rpm": [
          "audacity"
        ],
        "pacman": [
          "audacity"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.kde.krita",
      "displayName": "Krita",
      "appstreamIds": [
        "org.kde.krita"
      ],
      "homepages": [
        "krita.org"
      ],
      "backends": {
        "snap": [
          "krita"
        ],
        "deb": [
          "krita"
        ],
        "flatpak": [
          "org.kde.krita"
        ],
        "rpm": [
          "krita"
        ],
        "pacman": [
          "krita"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.libreoffice.LibreOffice",
      "displayName": "LibreOffice",
      "appstreamIds": [
        "org.libreoffice.LibreOffice"
      ],
      "homepages": [
        "libreoffice.org"
      ],
      "backends": {
        "snap": [
          "libreoffice"
        ],
        "deb": [
          "libreoffice"
        ],
        "flatpak": [
          "org.libreoffice.LibreOffice"
        ],
        "rpm": [
          "libreoffice"
        ],
        "pacman": [
          "libreoffice-fresh"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:com.visualstudio.code",
      "displayName": "Visual Studio Code",
      "appstreamIds": [
        "com.visualstudio.code"
      ],
      "homepages": [
        "code.visualstudio.com"
      ],
      "backends": {
        "snap": [
          "code"
        ],
        "deb": [
          "code"
        ],
        "flatpak": [
          "com.visualstudio.code"
        ],
        "rpm": [
          "code"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.telegram.desktop",
      "displayName": "Telegram",
      "appstreamIds": [
        "org.telegram.desktop"
      ],
      "homepages": [
        "telegram.org"
      ],
      "backends": {
        "snap": [
          "telegram-desktop"
        ],
        "deb": [
          "telegram-desktop"
        ],
        "flatpak": [
          "org.telegram.desktop"
        ],
        "rpm": [
          "telegram-desktop"
        ],
        "pacman": [
          "telegram-desktop"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:com.discordapp.Discord",
      "displayName": "Discord",
      "appstreamIds": [
        "com.discordapp.Discord"
      ],
      "homepages": [
        "discord.com"
      ],
      "backends": {
        "snap": [
          "discord"
        ],
        "flatpak": [
          "com.discordapp.Discord"
        ],
        "pacman": [
          "discord"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:com.spotify.Client",
      "displayName": "Spotify",
      "appstreamIds": [
        "com.spotify.Client"
      ],
      "homepages": [
        "spotify.com"
      ],
      "backends": {
        "snap": [
          "spotify"
        ],
        "flatpak": [
          "com.spotify.Client"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:com.valvesoftware.Steam",
      "displayName": "Steam",
      "appstreamIds": [
        "com.valvesoftware.Steam"
      ],
      "homepages": [
        "store.steampowered.com"
      ],
      "backends": {
        "snap": [
          "steam"
        ],
        "deb": [
          "steam"
        ],
        "flatpak": [
          "com.valvesoftware.Steam"
        ],
        "pacman": [
          "steam"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "canonicalId": "appstream:org.keepassxc.KeePassXC",
      "displayName": "KeePassXC",
      "appstreamIds": [
        "org.keepassxc.KeePassXC"
      ],
      "homepages": [
        "keepassxc.org"
      ],
      "backends": {
        "snap": [
          "keepassxc"
        ],
        "deb": [
          "keepassxc"
        ],
        "flatpak": [
          "org.keepassxc.KeePassXC"
        ],
        "rpm": [
          "keepassxc"
        ],
        "pacman": [
          "keepassxc"
        ]
      },
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-27T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.google.Chrome"
      ],
      "backends": {
        "deb": [
          "google-chrome-stable"
        ],
        "flatpak": [
          "com.google.Chrome"
        ],
        "rpm": [
          "google-chrome-stable"
        ]
      },
      "canonicalId": "appstream:com.google.Chrome",
      "displayName": "Google Chrome",
      "homepages": [
        "google.com/chrome"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.brave.Browser"
      ],
      "backends": {
        "deb": [
          "brave-browser"
        ],
        "flatpak": [
          "com.brave.Browser"
        ],
        "rpm": [
          "brave-browser"
        ],
        "snap": [
          "brave"
        ]
      },
      "canonicalId": "appstream:com.brave.Browser",
      "displayName": "Brave Browser",
      "homepages": [
        "brave.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.opera.Opera"
      ],
      "backends": {
        "deb": [
          "opera-stable"
        ],
        "flatpak": [
          "com.opera.Opera"
        ],
        "pacman": [
          "opera"
        ],
        "rpm": [
          "opera-stable"
        ],
        "snap": [
          "opera"
        ]
      },
      "canonicalId": "appstream:com.opera.Opera",
      "displayName": "Opera",
      "homepages": [
        "opera.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.vivaldi.Vivaldi"
      ],
      "backends": {
        "deb": [
          "vivaldi-stable"
        ],
        "flatpak": [
          "com.vivaldi.Vivaldi"
        ],
        "rpm": [
          "vivaldi-stable"
        ]
      },
      "canonicalId": "appstream:com.vivaldi.Vivaldi",
      "displayName": "Vivaldi",
      "homepages": [
        "vivaldi.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.torproject.torbrowser-launcher"
      ],
      "backends": {
        "deb": [
          "torbrowser-launcher"
        ],
        "flatpak": [
          "org.torproject.torbrowser-launcher"
        ],
        "pacman": [
          "torbrowser-launcher"
        ],
        "rpm": [
          "torbrowser-launcher"
        ]
      },
      "canonicalId": "appstream:org.torproject.torbrowser-launcher",
      "displayName": "Tor Browser Launcher",
      "homepages": [
        "torproject.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.kde.falkon"
      ],
      "backends": {
        "deb": [
          "falkon"
        ],
        "flatpak": [
          "org.kde.falkon"
        ],
        "pacman": [
          "falkon"
        ],
        "rpm": [
          "falkon"
        ]
      },
      "canonicalId": "appstream:org.kde.falkon",
      "displayName": "Falkon",
      "homepages": [
        "falkon.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Epiphany"
      ],
      "backends": {
        "deb": [
          "epiphany-browser"
        ],
        "flatpak": [
          "org.gnome.Epiphany"
        ],
        "pacman": [
          "epiphany"
        ],
        "rpm": [
          "epiphany"
        ]
      },
      "canonicalId": "appstream:org.gnome.Epiphany",
      "displayName": "GNOME Web",
      "homepages": [
        "apps.gnome.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "one.ablaze.floorp"
      ],
      "backends": {
        "flatpak": [
          "one.ablaze.floorp"
        ],
        "pacman": [
          "floorp"
        ]
      },
      "canonicalId": "appstream:one.ablaze.floorp",
      "displayName": "Floorp",
      "homepages": [
        "floorp.app"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.jetbrains.IntelliJ-IDEA-Community"
      ],
      "backends": {
        "flatpak": [
          "com.jetbrains.IntelliJ-IDEA-Community"
        ],
        "pacman": [
          "intellij-idea-community-edition"
        ],
        "snap": [
          "intellij-idea-community"
        ]
      },
      "canonicalId": "appstream:com.jetbrains.IntelliJ-IDEA-Community",
      "displayName": "IntelliJ IDEA Community",
      "homepages": [
        "jetbrains.com/idea"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.google.AndroidStudio"
      ],
      "backends": {
        "flatpak": [
          "com.google.AndroidStudio"
        ],
        "snap": [
          "android-studio"
        ]
      },
      "canonicalId": "appstream:com.google.AndroidStudio",
      "displayName": "Android Studio",
      "homepages": [
        "developer.android.com/studio"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.getpostman.Postman"
      ],
      "backends": {
        "flatpak": [
          "com.getpostman.Postman"
        ],
        "snap": [
          "postman"
        ]
      },
      "canonicalId": "appstream:com.getpostman.Postman",
      "displayName": "Postman",
      "homepages": [
        "postman.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "io.dbeaver.DBeaverCommunity"
      ],
      "backends": {
        "deb": [
          "dbeaver-ce"
        ],
        "flatpak": [
          "io.dbeaver.DBeaverCommunity"
        ],
        "pacman": [
          "dbeaver"
        ],
        "rpm": [
          "dbeaver-ce"
        ],
        "snap": [
          "dbeaver-ce"
        ]
      },
      "canonicalId": "appstream:io.dbeaver.DBeaverCommunity",
      "displayName": "DBeaver Community",
      "homepages": [
        "dbeaver.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "io.neovim.nvim"
      ],
      "backends": {
        "deb": [
          "neovim"
        ],
        "flatpak": [
          "io.neovim.nvim"
        ],
        "pacman": [
          "neovim"
        ],
        "rpm": [
          "neovim"
        ]
      },
      "canonicalId": "appstream:io.neovim.nvim",
      "displayName": "Neovim",
      "homepages": [
        "neovim.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnu.emacs"
      ],
      "backends": {
        "deb": [
          "emacs"
        ],
        "flatpak": [
          "org.gnu.emacs"
        ],
        "pacman": [
          "emacs"
        ],
        "rpm": [
          "emacs"
        ],
        "snap": [
          "emacs"
        ]
      },
      "canonicalId": "appstream:org.gnu.emacs",
      "displayName": "GNU Emacs",
      "homepages": [
        "gnu.org/software/emacs"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.geany.Geany"
      ],
      "backends": {
        "deb": [
          "geany"
        ],
        "flatpak": [
          "org.geany.Geany"
        ],
        "pacman": [
          "geany"
        ],
        "rpm": [
          "geany"
        ]
      },
      "canonicalId": "appstream:org.geany.Geany",
      "displayName": "Geany",
      "homepages": [
        "geany.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.calibre_ebook.calibre"
      ],
      "backends": {
        "deb": [
          "calibre"
        ],
        "flatpak": [
          "com.calibre_ebook.calibre"
        ],
        "pacman": [
          "calibre"
        ],
        "rpm": [
          "calibre"
        ]
      },
      "canonicalId": "appstream:com.calibre_ebook.calibre",
      "displayName": "Calibre",
      "homepages": [
        "calibre-ebook.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "fr.handbrake.ghb"
      ],
      "backends": {
        "deb": [
          "handbrake"
        ],
        "flatpak": [
          "fr.handbrake.ghb"
        ],
        "pacman": [
          "handbrake"
        ]
      },
      "canonicalId": "appstream:fr.handbrake.ghb",
      "displayName": "HandBrake",
      "homepages": [
        "handbrake.fr"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "info.smplayer.SMPlayer"
      ],
      "backends": {
        "deb": [
          "smplayer"
        ],
        "flatpak": [
          "info.smplayer.SMPlayer"
        ],
        "pacman": [
          "smplayer"
        ],
        "rpm": [
          "smplayer"
        ]
      },
      "canonicalId": "appstream:info.smplayer.SMPlayer",
      "displayName": "SMPlayer",
      "homepages": [
        "smplayer.info"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "io.github.celluloid_player.Celluloid"
      ],
      "backends": {
        "deb": [
          "celluloid"
        ],
        "flatpak": [
          "io.github.celluloid_player.Celluloid"
        ],
        "pacman": [
          "celluloid"
        ],
        "rpm": [
          "celluloid"
        ],
        "snap": [
          "celluloid"
        ]
      },
      "canonicalId": "appstream:io.github.celluloid_player.Celluloid",
      "displayName": "Celluloid",
      "homepages": [
        "celluloid-player.github.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "io.lmms.LMMS"
      ],
      "backends": {
        "deb": [
          "lmms"
        ],
        "flatpak": [
          "io.lmms.LMMS"
        ],
        "rpm": [
          "lmms"
        ]
      },
      "canonicalId": "appstream:io.lmms.LMMS",
      "displayName": "LMMS",
      "homepages": [
        "lmms.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "io.mpv.Mpv"
      ],
      "backends": {
        "deb": [
          "mpv"
        ],
        "flatpak": [
          "io.mpv.Mpv"
        ],
        "pacman": [
          "mpv"
        ],
        "rpm": [
          "mpv"
        ]
      },
      "canonicalId": "appstream:io.mpv.Mpv",
      "displayName": "MPV",
      "homepages": [
        "mpv.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.ardour.Ardour"
      ],
      "backends": {
        "deb": [
          "ardour"
        ],
        "flatpak": [
          "org.ardour.Ardour"
        ],
        "pacman": [
          "ardour"
        ],
        "rpm": [
          "ardour"
        ]
      },
      "canonicalId": "appstream:org.ardour.Ardour",
      "displayName": "Ardour",
      "homepages": [
        "ardour.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Calendar"
      ],
      "backends": {
        "deb": [
          "gnome-calendar"
        ],
        "flatpak": [
          "org.gnome.Calendar"
        ],
        "pacman": [
          "gnome-calendar"
        ],
        "rpm": [
          "gnome-calendar"
        ]
      },
      "canonicalId": "appstream:org.gnome.Calendar",
      "displayName": "GNOME Calendar",
      "homepages": [
        "apps.gnome.org/Calendar"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Evince"
      ],
      "backends": {
        "deb": [
          "evince"
        ],
        "flatpak": [
          "org.gnome.Evince"
        ],
        "pacman": [
          "evince"
        ],
        "rpm": [
          "evince"
        ]
      },
      "canonicalId": "appstream:org.gnome.Evince",
      "displayName": "Evince",
      "homepages": [
        "wiki.gnome.org/Apps/Evince"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Evolution"
      ],
      "backends": {
        "deb": [
          "evolution"
        ],
        "flatpak": [
          "org.gnome.Evolution"
        ],
        "pacman": [
          "evolution"
        ],
        "rpm": [
          "evolution"
        ]
      },
      "canonicalId": "appstream:org.gnome.Evolution",
      "displayName": "Evolution",
      "homepages": [
        "wiki.gnome.org/Apps/Evolution"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Geary"
      ],
      "backends": {
        "deb": [
          "geary"
        ],
        "flatpak": [
          "org.gnome.Geary"
        ],
        "pacman": [
          "geary"
        ],
        "rpm": [
          "geary"
        ]
      },
      "canonicalId": "appstream:org.gnome.Geary",
      "displayName": "Geary",
      "homepages": [
        "wiki.gnome.org/Apps/Geary"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Rhythmbox3"
      ],
      "backends": {
        "deb": [
          "rhythmbox"
        ],
        "flatpak": [
          "org.gnome.Rhythmbox3"
        ],
        "pacman": [
          "rhythmbox"
        ],
        "rpm": [
          "rhythmbox"
        ]
      },
      "canonicalId": "appstream:org.gnome.Rhythmbox3",
      "displayName": "Rhythmbox",
      "homepages": [
        "wiki.gnome.org/Apps/Rhythmbox"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnucash.GnuCash"
      ],
      "backends": {
        "deb": [
          "gnucash"
        ],
        "flatpak": [
          "org.gnucash.GnuCash"
        ],
        "pacman": [
          "gnucash"
        ],
        "rpm": [
          "gnucash"
        ]
      },
      "canonicalId": "appstream:org.gnucash.GnuCash",
      "displayName": "GnuCash",
      "homepages": [
        "gnucash.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.kde.elisa"
      ],
      "backends": {
        "deb": [
          "elisa"
        ],
        "flatpak": [
          "org.kde.elisa"
        ],
        "pacman": [
          "elisa"
        ]
      },
      "canonicalId": "appstream:org.kde.elisa",
      "displayName": "Elisa",
      "homepages": [
        "apps.kde.org/elisa"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.kde.kaffeine"
      ],
      "backends": {
        "deb": [
          "kaffeine"
        ],
        "flatpak": [
          "org.kde.kaffeine"
        ],
        "pacman": [
          "kaffeine"
        ],
        "rpm": [
          "kaffeine"
        ]
      },
      "canonicalId": "appstream:org.kde.kaffeine",
      "displayName": "Kaffeine",
      "homepages": [
        "apps.kde.org/kaffeine"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.onlyoffice.desktopeditors"
      ],
      "backends": {
        "flatpak": [
          "org.onlyoffice.desktopeditors"
        ],
        "snap": [
          "onlyoffice-desktopeditors"
        ]
      },
      "canonicalId": "appstream:org.onlyoffice.desktopeditors",
      "displayName": "ONLYOFFICE Desktop Editors",
      "homepages": [
        "onlyoffice.com/desktop"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.pitivi.Pitivi"
      ],
      "backends": {
        "deb": [
          "pitivi"
        ],
        "flatpak": [
          "org.pitivi.Pitivi"
        ],
        "pacman": [
          "pitivi"
        ],
        "rpm": [
          "pitivi"
        ]
      },
      "canonicalId": "appstream:org.pitivi.Pitivi",
      "displayName": "Pitivi",
      "homepages": [
        "pitivi.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.shotcut.Shotcut"
      ],
      "backends": {
        "flatpak": [
          "org.shotcut.Shotcut"
        ],
        "snap": [
          "shotcut"
        ]
      },
      "canonicalId": "appstream:org.shotcut.Shotcut",
      "displayName": "Shotcut",
      "homepages": [
        "shotcut.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.strawberrymusicplayer.strawberry"
      ],
      "backends": {
        "deb": [
          "strawberry"
        ],
        "flatpak": [
          "org.strawberrymusicplayer.strawberry"
        ],
        "rpm": [
          "strawberry"
        ]
      },
      "canonicalId": "appstream:org.strawberrymusicplayer.strawberry",
      "displayName": "Strawberry",
      "homepages": [
        "strawberrymusicplayer.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.xfce.Parole"
      ],
      "backends": {
        "deb": [
          "parole"
        ],
        "rpm": [
          "parole"
        ]
      },
      "canonicalId": "appstream:org.xfce.Parole",
      "displayName": "Parole",
      "homepages": [
        "docs.xfce.org/apps/parole/start"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.signal.Signal"
      ],
      "backends": {
        "deb": [
          "signal-desktop"
        ],
        "flatpak": [
          "org.signal.Signal"
        ],
        "pacman": [
          "signal-desktop"
        ],
        "snap": [
          "signal-desktop"
        ]
      },
      "canonicalId": "appstream:org.signal.Signal",
      "displayName": "Signal Desktop",
      "homepages": [
        "signal.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "im.riot.Riot"
      ],
      "backends": {
        "deb": [
          "element-desktop"
        ],
        "flatpak": [
          "im.riot.Riot"
        ],
        "rpm": [
          "element-desktop"
        ]
      },
      "canonicalId": "appstream:im.riot.Riot",
      "displayName": "Element",
      "homepages": [
        "element.io"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.slack.Slack"
      ],
      "backends": {
        "deb": [
          "slack-desktop"
        ],
        "flatpak": [
          "com.slack.Slack"
        ],
        "rpm": [
          "slack"
        ],
        "snap": [
          "slack"
        ]
      },
      "canonicalId": "appstream:com.slack.Slack",
      "displayName": "Slack",
      "homepages": [
        "slack.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "us.zoom.Zoom"
      ],
      "backends": {
        "deb": [
          "zoom"
        ],
        "flatpak": [
          "us.zoom.Zoom"
        ],
        "pacman": [
          "zoom"
        ],
        "rpm": [
          "zoom"
        ],
        "snap": [
          "zoom-client"
        ]
      },
      "canonicalId": "appstream:us.zoom.Zoom",
      "displayName": "Zoom",
      "homepages": [
        "zoom.us"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "im.pidgin.Pidgin"
      ],
      "backends": {
        "deb": [
          "pidgin"
        ],
        "flatpak": [
          "im.pidgin.Pidgin"
        ],
        "pacman": [
          "pidgin"
        ],
        "rpm": [
          "pidgin"
        ]
      },
      "canonicalId": "appstream:im.pidgin.Pidgin",
      "displayName": "Pidgin",
      "homepages": [
        "pidgin.im"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "im.dino.Dino"
      ],
      "backends": {
        "deb": [
          "dino-im"
        ],
        "flatpak": [
          "im.dino.Dino"
        ],
        "pacman": [
          "dino"
        ],
        "rpm": [
          "dino"
        ]
      },
      "canonicalId": "appstream:im.dino.Dino",
      "displayName": "Dino",
      "homepages": [
        "dino.im"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "network.loki.Session"
      ],
      "backends": {
        "deb": [
          "session-desktop"
        ],
        "flatpak": [
          "network.loki.Session"
        ]
      },
      "canonicalId": "appstream:network.loki.Session",
      "displayName": "Session Desktop",
      "homepages": [
        "getsession.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.darktable.Darktable"
      ],
      "backends": {
        "deb": [
          "darktable"
        ],
        "flatpak": [
          "org.darktable.Darktable"
        ],
        "pacman": [
          "darktable"
        ],
        "rpm": [
          "darktable"
        ],
        "snap": [
          "darktable"
        ]
      },
      "canonicalId": "appstream:org.darktable.Darktable",
      "displayName": "darktable",
      "homepages": [
        "darktable.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.rawtherapee.RawTherapee"
      ],
      "backends": {
        "deb": [
          "rawtherapee"
        ],
        "flatpak": [
          "com.rawtherapee.RawTherapee"
        ],
        "pacman": [
          "rawtherapee"
        ],
        "rpm": [
          "rawtherapee"
        ]
      },
      "canonicalId": "appstream:com.rawtherapee.RawTherapee",
      "displayName": "RawTherapee",
      "homepages": [
        "rawtherapee.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.kde.digikam"
      ],
      "backends": {
        "deb": [
          "digikam"
        ],
        "flatpak": [
          "org.kde.digikam"
        ],
        "pacman": [
          "digikam"
        ],
        "rpm": [
          "digikam"
        ],
        "snap": [
          "digikam"
        ]
      },
      "canonicalId": "appstream:org.kde.digikam",
      "displayName": "digiKam",
      "homepages": [
        "digikam.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.Shotwell"
      ],
      "backends": {
        "deb": [
          "shotwell"
        ],
        "flatpak": [
          "org.gnome.Shotwell"
        ],
        "pacman": [
          "shotwell"
        ],
        "rpm": [
          "shotwell"
        ],
        "snap": [
          "shotwell"
        ]
      },
      "canonicalId": "appstream:org.gnome.Shotwell",
      "displayName": "Shotwell",
      "homepages": [
        "shotwell-project.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.github.PintaProject.Pinta"
      ],
      "backends": {
        "deb": [
          "pinta"
        ],
        "flatpak": [
          "com.github.PintaProject.Pinta"
        ],
        "pacman": [
          "pinta"
        ],
        "rpm": [
          "pinta"
        ],
        "snap": [
          "pinta"
        ]
      },
      "canonicalId": "appstream:com.github.PintaProject.Pinta",
      "displayName": "Pinta",
      "homepages": [
        "pinta-project.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.mypaint.MyPaint"
      ],
      "backends": {
        "deb": [
          "mypaint"
        ],
        "flatpak": [
          "org.mypaint.MyPaint"
        ],
        "pacman": [
          "mypaint"
        ],
        "rpm": [
          "mypaint"
        ]
      },
      "canonicalId": "appstream:org.mypaint.MyPaint",
      "displayName": "MyPaint",
      "homepages": [
        "mypaint.app"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.kde.gwenview"
      ],
      "backends": {
        "flatpak": [
          "org.kde.gwenview"
        ],
        "snap": [
          "gwenview"
        ]
      },
      "canonicalId": "appstream:org.kde.gwenview",
      "displayName": "Gwenview",
      "homepages": [
        "apps.kde.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.eog"
      ],
      "backends": {
        "deb": [
          "eog"
        ],
        "flatpak": [
          "org.gnome.eog"
        ],
        "pacman": [
          "eog"
        ],
        "rpm": [
          "eog"
        ],
        "snap": [
          "eog"
        ]
      },
      "canonicalId": "appstream:org.gnome.eog",
      "displayName": "Eye of GNOME",
      "homepages": [
        "wiki.gnome.org/Apps/EyeOfGnome"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.nomacs.ImageLounge"
      ],
      "backends": {
        "deb": [
          "nomacs"
        ],
        "flatpak": [
          "org.nomacs.ImageLounge"
        ],
        "pacman": [
          "nomacs"
        ],
        "rpm": [
          "nomacs"
        ]
      },
      "canonicalId": "appstream:org.nomacs.ImageLounge",
      "displayName": "nomacs",
      "homepages": [
        "nomacs.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.photoqt.PhotoQt"
      ],
      "backends": {
        "deb": [
          "photoqt"
        ],
        "flatpak": [
          "org.photoqt.PhotoQt"
        ],
        "rpm": [
          "photoqt"
        ]
      },
      "canonicalId": "appstream:org.photoqt.PhotoQt",
      "displayName": "PhotoQt",
      "homepages": [
        "photoqt.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "net.lutris.Lutris"
      ],
      "backends": {
        "deb": [
          "lutris"
        ],
        "flatpak": [
          "net.lutris.Lutris"
        ],
        "rpm": [
          "lutris"
        ],
        "snap": [
          "lutris"
        ]
      },
      "canonicalId": "appstream:net.lutris.Lutris",
      "displayName": "Lutris",
      "homepages": [
        "lutris.net"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.libretro.RetroArch"
      ],
      "backends": {
        "flatpak": [
          "org.libretro.RetroArch"
        ],
        "snap": [
          "retroarch"
        ]
      },
      "canonicalId": "appstream:org.libretro.RetroArch",
      "displayName": "RetroArch",
      "homepages": [
        "retroarch.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.DolphinEmu.dolphin-emu"
      ],
      "backends": {
        "deb": [
          "dolphin-emu"
        ],
        "flatpak": [
          "org.DolphinEmu.dolphin-emu"
        ],
        "pacman": [
          "dolphin-emu"
        ],
        "rpm": [
          "dolphin-emu"
        ]
      },
      "canonicalId": "appstream:org.DolphinEmu.dolphin-emu",
      "displayName": "Dolphin Emulator",
      "homepages": [
        "dolphin-emu.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "net.pcsx2.PCSX2"
      ],
      "backends": {
        "deb": [
          "pcsx2"
        ],
        "flatpak": [
          "net.pcsx2.PCSX2"
        ],
        "pacman": [
          "pcsx2"
        ]
      },
      "canonicalId": "appstream:net.pcsx2.PCSX2",
      "displayName": "PCSX2",
      "homepages": [
        "pcsx2.net"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.winehq.Wine"
      ],
      "backends": {
        "deb": [
          "winehq-stable"
        ],
        "flatpak": [
          "org.winehq.Wine"
        ],
        "rpm": [
          "wine"
        ]
      },
      "canonicalId": "appstream:org.winehq.Wine",
      "displayName": "Wine",
      "homepages": [
        "winehq.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.ppsspp.PPSSPP"
      ],
      "backends": {
        "deb": [
          "ppsspp"
        ],
        "flatpak": [
          "org.ppsspp.PPSSPP"
        ]
      },
      "canonicalId": "appstream:org.ppsspp.PPSSPP",
      "displayName": "PPSSPP",
      "homepages": [
        "ppsspp.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.prismlauncher.PrismLauncher"
      ],
      "backends": {
        "deb": [
          "prismlauncher"
        ],
        "flatpak": [
          "org.prismlauncher.PrismLauncher"
        ],
        "pacman": [
          "prismlauncher"
        ],
        "rpm": [
          "prismlauncher"
        ]
      },
      "canonicalId": "appstream:org.prismlauncher.PrismLauncher",
      "displayName": "Prism Launcher",
      "homepages": [
        "prismlauncher.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.bitwarden.desktop"
      ],
      "backends": {
        "flatpak": [
          "com.bitwarden.desktop"
        ],
        "snap": [
          "bitwarden"
        ]
      },
      "canonicalId": "appstream:com.bitwarden.desktop",
      "displayName": "Bitwarden",
      "homepages": [
        "bitwarden.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.flameshot.Flameshot"
      ],
      "backends": {
        "deb": [
          "flameshot"
        ],
        "flatpak": [
          "org.flameshot.Flameshot"
        ],
        "pacman": [
          "flameshot"
        ],
        "rpm": [
          "flameshot"
        ]
      },
      "canonicalId": "appstream:org.flameshot.Flameshot",
      "displayName": "Flameshot",
      "homepages": [
        "flameshot.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.DejaDup"
      ],
      "backends": {
        "deb": [
          "deja-dup"
        ],
        "flatpak": [
          "org.gnome.DejaDup"
        ],
        "pacman": [
          "deja-dup"
        ],
        "rpm": [
          "deja-dup"
        ],
        "snap": [
          "deja-dup"
        ]
      },
      "canonicalId": "appstream:org.gnome.DejaDup",
      "displayName": "Déjà Dup",
      "homepages": [
        "wiki.gnome.org/Apps/DejaDup"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "com.transmissionbt.Transmission"
      ],
      "backends": {
        "deb": [
          "transmission-gtk"
        ],
        "flatpak": [
          "com.transmissionbt.Transmission"
        ]
      },
      "canonicalId": "appstream:com.transmissionbt.Transmission",
      "displayName": "Transmission",
      "homepages": [
        "transmissionbt.com"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.qbittorrent.qBittorrent"
      ],
      "backends": {
        "deb": [
          "qbittorrent"
        ],
        "flatpak": [
          "org.qbittorrent.qBittorrent"
        ],
        "snap": [
          "qbittorrent-desktop-tak"
        ]
      },
      "canonicalId": "appstream:org.qbittorrent.qBittorrent",
      "displayName": "qBittorrent",
      "homepages": [
        "qbittorrent.org"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.baobab"
      ],
      "backends": {
        "deb": [
          "baobab"
        ],
        "flatpak": [
          "org.gnome.baobab"
        ],
        "rpm": [
          "baobab"
        ]
      },
      "canonicalId": "appstream:org.gnome.baobab",
      "displayName": "Baobab",
      "homepages": [
        "apps.gnome.org/Baobab"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    },
    {
      "appstreamIds": [
        "org.gnome.DiskUtility"
      ],
      "backends": {
        "deb": [
          "gnome-disk-utility"
        ],
        "pacman": [
          "gnome-disk-utility"
        ],
        "rpm": [
          "gnome-disk-utility"
        ]
      },
      "canonicalId": "appstream:org.gnome.DiskUtility",
      "displayName": "GNOME Disks",
      "homepages": [
        "apps.gnome.org/DiskUtility"
      ],
      "provenance": {
        "source": "seed",
        "updatedAt": "2026-09-28T00:00:00Z"
      }
    }
  ],
  "aliases": {}
}''';
