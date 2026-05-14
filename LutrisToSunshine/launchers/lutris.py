import os
import yaml
import shlex
from typing import Optional, List, Tuple, Dict
from utils.utils import run_command, parse_json_output

def get_lutris_command(args: str = "") -> Optional[str]:
    """Get the appropriate Lutris command based on installation type."""
    # Check for Flatpak installation
    if run_command("flatpak list | grep net.lutris.Lutris").returncode == 0:
        base_cmd = "flatpak run net.lutris.Lutris"
    # Check for native installation
    elif run_command("which lutris").returncode == 0:
        base_cmd = "/usr/bin/python3 /usr/bin/lutris"
    else:
        return None

    return f"{base_cmd} {args}".strip()

def is_lutris_running() -> bool:
    """Check if Lutris is currently running."""
    our_script_name = os.path.basename(__file__)
    cmd = f"ps aux | grep -v grep | grep -v {our_script_name} | grep -E " + r"'(^|\s)lutris($|\s)|net\.lutris\.Lutris'"
    result = run_command(cmd)
    return result.returncode == 0 and result.stdout.strip() != b''

def list_lutris_games() -> List[Tuple[str, str]]:
    """List all games in Lutris."""
    lutris_cmd = get_lutris_command()
    cmd = f"{lutris_cmd} -lo --json"
    result = run_command(cmd)
    games = parse_json_output(result)
    return [(game['id'], game['name']) for game in games] if games else []


LUTRIS_GAMES_DIR = os.path.expanduser("~/.local/share/lutris/games/")


def _find_game_yaml(slug: str) -> Optional[str]:
    """Find the YAML config file for a Lutris game by slug.

    YAML files are named <slug>-<timestamp>.yml in a flat directory.
    """
    if not os.path.isdir(LUTRIS_GAMES_DIR):
        return None

    for filename in os.listdir(LUTRIS_GAMES_DIR):
        if filename.startswith(slug + "-") and filename.endswith(".yml"):
            return os.path.join(LUTRIS_GAMES_DIR, filename)
    return None


def resolve_lutris_game(slug: str) -> Optional[Dict[str, str]]:
    """
    Read Lutris YAML config for a game and resolve executable path.
    Returns dict with keys: exe, workingdir, args, prefix, resolved_cmd
    or None if resolution fails.
    """
    yaml_path = _find_game_yaml(slug)
    if not yaml_path:
        return None

    try:
        with open(yaml_path, "r") as f:
            config = yaml.safe_load(f)
    except Exception:
        return None

    if not config or not isinstance(config, dict):
        return None

    game_config = config.get("game", {})
    if not game_config or not isinstance(game_config, dict):
        return None

    # Get exe path - could be absolute or Wine-relative (e.g., drive_c/...)
    exe = game_config.get("exe", "")
    if not exe:
        # Try main_file for emulator games
        exe = game_config.get("main_file", "")

    if not exe:
        return None

    working_dir = game_config.get("working_dir", "")
    args = game_config.get("args", "")
    prefix = game_config.get("prefix", "")

    # If exe is Wine-relative (e.g., drive_c/Games/...), prepend prefix
    if not os.path.isabs(exe) and prefix:
        exe = os.path.join(prefix, exe.lstrip("/\\"))

    # Expand user home and env vars
    exe = os.path.expanduser(exe)
    exe = os.path.expandvars(exe)
    if working_dir:
        working_dir = os.path.expanduser(working_dir)
        working_dir = os.path.expandvars(working_dir)

    # Verify exe exists
    if not os.path.exists(exe):
        print(f"Warning: Executable not found for {slug}: {exe}")
        return None

    # Build resolved command
    if args:
        resolved_cmd = f'"{exe}" {args}'
    else:
        resolved_cmd = exe

    return {
        "exe": exe,
        "workingdir": working_dir,
        "args": args,
        "prefix": prefix,
        "resolved_cmd": resolved_cmd,
    }


def list_lutris_games_with_paths() -> List[Tuple[str, str, str]]:
    """
    List Lutris games with resolved executable paths.
    Returns [(game_id, game_name, resolved_cmd), ...]
    Skips games where exe resolution fails.
    """
    lutris_cmd = get_lutris_command()
    if not lutris_cmd:
        return []

    # Get full game list with slugs
    result = run_command(f"{lutris_cmd} -lo --json")
    games = parse_json_output(result)
    if not games:
        return []

    results = []
    for game in games:
        game_id = str(game.get("id", ""))
        game_name = game.get("name", "")
        slug = game.get("slug", "")

        if not slug:
            continue

        path_info = resolve_lutris_game(slug)
        if path_info:
            results.append((game_id, game_name, path_info["resolved_cmd"]))

    return results
