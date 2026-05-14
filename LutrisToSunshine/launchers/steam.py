import os
import re
import vdf
import shutil
from typing import Tuple, List, Optional, Dict, Set
import hashlib
import json
from utils.utils import run_command

STEAM_FLATPAK_ID = "com.valvesoftware.Steam"

def detect_steam_installation() -> Tuple[bool, str]:
    """Detect if Steam is installed and how."""
    # Check for Flatpak installation
    if run_command(f"flatpak list | grep {STEAM_FLATPAK_ID}").returncode == 0:
        return True, "flatpak"
    # Check for native installation
    elif run_command("which steam").returncode == 0:
        return True, "native"
    else:
        return False, ""

def get_steam_root(installation_type: str) -> str:
    """Get the Steam root directory based on installation type."""
    if installation_type == "flatpak":
        return os.path.expanduser("~/.var/app/com.valvesoftware.Steam/.steam/steam")
    else:
        return os.path.expanduser("~/.steam/steam")

def parse_vdf_value(line: str) -> Optional[str]:
    """Parse a VDF value from a line like '"key" "value"'."""
    match = re.match(r'^\s*"[^"]*"\s*"([^"]*)"', line)
    return match.group(1) if match else None

def parse_libraryfolders(vdf_path: str) -> List[str]:
    """Parse libraryfolders.vdf to get library paths."""
    if not os.path.exists(vdf_path):
        return []
    
    paths = []
    with open(vdf_path, 'r') as f:
        content = f.read()
    
    # Simple parsing for library folders
    # Look for "path" entries
    for match in re.finditer(r'"path"\s*"([^"]*)"', content):
        paths.append(match.group(1))
    
    return paths

def parse_appmanifest(manifest_path: str) -> Optional[Tuple[str, str]]:
    """Parse appmanifest_*.acf to get appid and name."""
    if not os.path.exists(manifest_path):
        return None
    
    appid = None
    name = None
    with open(manifest_path, 'r') as f:
        for line in f:
            if '"appid"' in line:
                appid = parse_vdf_value(line)
            elif '"name"' in line:
                name = parse_vdf_value(line)
            if appid and name:
                break
    
    if appid and name:
        return appid, name
    return None

def list_steam_games() -> List[Tuple[str, str]]:
    """List all Steam games."""
    installed, installation_type = detect_steam_installation()
    if not installed:
        return []
    
    steam_root = get_steam_root(installation_type)
    libraryfolders_path = os.path.join(steam_root, "config", "libraryfolders.vdf")
    
    library_paths = parse_libraryfolders(libraryfolders_path)
    if not library_paths:
        # Fallback to default steamapps
        library_paths = [os.path.join(steam_root, "steamapps")]
    
    games = []
    exclude_patterns = ["proton", "steam linux runtime", "steamworks common", "steamvr"]
    for lib_path in library_paths:
        steamapps_path = os.path.join(lib_path, "steamapps")
        if os.path.exists(steamapps_path):
            for filename in os.listdir(steamapps_path):
                if filename.startswith("appmanifest_") and filename.endswith(".acf"):
                    manifest_path = os.path.join(steamapps_path, filename)
                    result = parse_appmanifest(manifest_path)
                    if result:
                        appid, name = result
                        # Filter out non-game items
                        if not any(name.lower().startswith(pattern) for pattern in exclude_patterns):
                            games.append((appid, name))
    
    return games

def get_steam_command() -> str:
    """Get the command to run Steam."""
    installed, installation_type = detect_steam_installation()
    if not installed:
        return ""

    if installation_type == "flatpak":
        return f"flatpak run {STEAM_FLATPAK_ID}"
    else:
        return "steam"


def _find_steam_userdata_dir() -> Optional[str]:
    """Find Steam's userdata directory by searching for localconfig.vdf."""
    steam_root = os.path.expanduser("~/.local/share/Steam")
    if not os.path.isdir(steam_root):
        # Try flatpak path
        steam_root = os.path.expanduser("~/.var/app/com.valvesoftware.Steam/.local/share/Steam")

    if not os.path.isdir(steam_root):
        return None

    for entry in os.listdir(steam_root):
        if entry.isdigit():
            config_path = os.path.join(steam_root, entry, "config", "localconfig.vdf")
            if os.path.exists(config_path):
                return os.path.join(steam_root, entry)

    # Fallback: search all subdirectories recursively
    for root, dirs, files in os.walk(steam_root):
        if "localconfig.vdf" in files:
            return os.path.dirname(root)

    return None


def _get_shortcuts_path() -> Optional[str]:
    """Get path to Steam's shortcuts.vdf (non-Steam games)."""
    userdata_dir = _find_steam_userdata_dir()
    if not userdata_dir:
        return None

    shortcuts_path = os.path.join(userdata_dir, "config", "shortcuts.vdf")
    if os.path.exists(shortcuts_path):
        return shortcuts_path

    # Final fallback: search for the file directly
    steam_root = os.path.expanduser("~/.local/share/Steam")
    if not os.path.isdir(steam_root):
        steam_root = os.path.expanduser("~/.var/app/com.valvesoftware.Steam/.local/share/Steam")

    if os.path.isdir(steam_root):
        for root, dirs, files in os.walk(steam_root):
            if "shortcuts.vdf" in files:
                return os.path.join(root, "shortcuts.vdf")

    return None


def list_steam_nonsteam_game_names() -> Set[str]:
    """
    List names of non-Steam games already in Steam library.
    Returns a set of game names to filter duplicates.
    """
    vdf_path = _get_shortcuts_path()
    if not vdf_path:
        return set()

    try:
        with open(vdf_path, "rb") as f:
            data = vdf.binary_load(f)
    except Exception:
        return set()

    shortcuts = data.get("shortcuts", {})
    nonsteam_names: Set[str] = set()
    for key, entry in shortcuts.items():
        if isinstance(entry, dict):
            app_name = entry.get("AppName")
            if app_name:
                nonsteam_names.add(app_name)

    return nonsteam_names


def _get_steam_grid_dir() -> Optional[str]:
    """Get the Steam grid cache directory for storing custom icons."""
    userdata_dir = _find_steam_userdata_dir()
    if not userdata_dir:
        return None

    grid_dir = os.path.join(userdata_dir, "config", "grid")
    return grid_dir if os.path.isdir(grid_dir) else None


def _next_shortcuts_key(shortcuts: Dict[str | int, object]) -> str | int:
    """Generate a new unique key for a shortcuts entry."""
    if not shortcuts:
        return 0
    # vdf may parse keys as strings or ints — handle both
    max_key = max(shortcuts.keys())
    if isinstance(max_key, str):
        # Try to convert to int, increment, return as string (matching vdf format)
        try:
            return str(int(max_key) + 1)
        except ValueError:
            return "999999"
    return max_key + 1


def _save_hero_image(game_name: str, icon_path: str, grid_dir: str) -> Optional[str]:
    """Save hero/banner image for a non-steam game.

    The hero filename is derived from the appid hash (same as Steam does).
    Returns the path to the saved hero file, or None if failed.
    """
    game_appid = int.from_bytes(hashlib.md5(game_name.encode()).digest()[:4], 'little') & 0x7FFFFFFF
    hero_filename = f"{game_appid & 0xFFFFFFFF}_hero.jpg"
    hero_dest = os.path.join(grid_dir, hero_filename)

    try:
        from PIL import Image
        img = Image.open(icon_path)
        img = img.resize((1920, 1080), Image.Resampling.LANCZOS)
        img = img.convert("RGB")
        img.save(hero_dest, "JPEG", quality=95)
        return hero_dest
    except Exception as e:
        print(f"Warning: Could not save hero image for '{game_name}': {e}")
        return None


def _create_librarycache_entry(game_name: str, grid_dir: str) -> bool:
    """Create librarycache JSON entry for a non-steam game's custom image."""
    game_appid = int.from_bytes(hashlib.md5(game_name.encode()).digest()[:4], 'little') & 0x7FFFFFFF

    cache_dir = os.path.join(os.path.dirname(grid_dir), "librarycache")
    os.makedirs(cache_dir, exist_ok=True)

    cache_file = os.path.join(cache_dir, f"{game_appid & 0xFFFFFFFF}.json")

    if os.path.exists(cache_file):
        try:
            with open(cache_file, 'r') as f:
                data = json.load(f)
            has_customimage = any(item[0] == "customimage" for item in data if isinstance(item, list))
            if not has_customimage:
                data.append(["customimage", {"version": 1}])
                with open(cache_file, 'w') as f:
                    json.dump(data, f)
            return True
        except Exception:
            pass

    data = [
        ["achievements", {"version": 2, "data": {"vecHighlight": [], "vecUnachieved": [], "vecAchievedHidden": [], "nTotal": 0, "nAchieved": 0}}],
        ["customimage", {"version": 1}]
    ]
    with open(cache_file, 'w') as f:
        json.dump(data, f)
    return True


def add_nonsteam_game_to_vdf(
    game_name: str,
    exe_path: str,
    start_dir: Optional[str] = None,
    icon_path: Optional[str] = None,
    force: bool = False,
) -> bool:
    """
    Add a non-Steam game entry to shortcuts.vdf.
    Returns True on success, False on failure.
    """
    vdf_path = _get_shortcuts_path()
    if not vdf_path:
        print("Error: Could not find Steam shortcuts.vdf.")
        return False

    # Read existing shortcuts
    try:
        with open(vdf_path, "rb") as f:
            data = vdf.binary_load(f)
    except Exception as e:
        print(f"Error reading shortcuts.vdf: {e}")
        return False

    shortcuts = data.setdefault("shortcuts", {})

    # Check for duplicate
    keys_to_delete = []
    for key, entry in shortcuts.items():
        if isinstance(entry, dict) and entry.get("AppName") == game_name:
            if force:
                print(f"Overwriting existing entry for '{game_name}'.")
                keys_to_delete.append(key)
            else:
                print(f"Warning: '{game_name}' already exists in Steam. Skipping.")
                return False
    for key in keys_to_delete:
        del shortcuts[key]

    # Generate a unique appid for this non-steam game from its name hash
    game_appid = int.from_bytes(hashlib.md5(game_name.encode()).digest()[:4], 'little') & 0x7FFFFFFF

    # Build entry
    entry: Dict[str, object] = {
        "appid": game_appid,  # Non-Steam game (positive 31-bit int for unique hero filename)
        "AppName": game_name,
        "Exe": exe_path,
        "IsHidden": False,
        "AllowDesktopConfig": False,
        "AllowOverlay": True,
        "OpenVR": False,
        "LastPlayTime": 0,
    }

    if start_dir:
        entry["StartDir"] = start_dir

    # Handle icon if provided
    # The 'icon' field in shortcuts.vdf is a direct path — Steam reads it directly.
    # Save to a persistent location (not Steam's internal grid/ dir).
    if icon_path and os.path.exists(icon_path):
        try:
            icon_dir = os.path.expanduser("~/.local/share/steamgrids")
            os.makedirs(icon_dir, exist_ok=True)
            icon_filename = f"{game_name.replace(' ', '_')}.png"
            icon_dest = os.path.join(icon_dir, icon_filename)
            shutil.copy2(icon_path, icon_dest)
            entry["icon"] = icon_dest

            # Also save hero/banner image for the library view
            grid_dir = _get_steam_grid_dir()
            if grid_dir:
                os.makedirs(grid_dir, exist_ok=True)
                hero_path = _save_hero_image(game_name, icon_path, grid_dir)
                if hero_path:
                    _create_librarycache_entry(game_name, grid_dir)
        except Exception as e:
            print(f"Warning: Could not save images for '{game_name}': {e}")

    # Add with a new unique key
    new_key = _next_shortcuts_key(shortcuts)
    shortcuts[new_key] = entry

    # Write back (use temp file + rename to handle Steam holding file open)
    try:
        tmp_path = vdf_path + ".tmp"
        with open(tmp_path, "wb") as f:
            vdf.binary_dump(data, f)
        os.replace(tmp_path, vdf_path)
        print(f"Added '{game_name}' to Steam as non-Steam game.")
        return True
    except Exception as e:
        print(f"Error writing shortcuts.vdf: {e}")
        # Clean up temp file if it exists
        tmp_path = vdf_path + ".tmp"
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        return False