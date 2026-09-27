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
  "generatedAt": "2026-09-27T00:00:00Z",
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
    }
  ],
  "aliases": {}
}''';
