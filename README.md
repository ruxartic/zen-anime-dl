# Zen API Anime Downloader (`zen-dl.sh`)

<div align="center">

[![Shell](https://img.shields.io/badge/Shell-Bash-8caaee?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-e5c890?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://opensource.org/licenses/MIT)
[![Stars](https://img.shields.io/github/stars/ruxartic/zen-anime-dl?style=flat-square&logo=github&color=babbf1&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/zen-anime-dl)
[![Forks](https://img.shields.io/github/forks/ruxartic/zen-anime-dl?style=flat-square&logo=github&color=a6d189&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/ruxartic/zen-anime-dl)
[![API](https://img.shields.io/badge/API-Zen%20API-ca9ee6?style=flat-square&logoColor=white&labelColor=292c3c&scale=2)](https://github.com/PacaHat/zen-api)

</div>

`zen-dl.sh` is a powerful command-line tool written in Bash to download anime series and episodes directly from a [Zen API](https://github.com/PacaHat/zen-api) instance. It offers features like anime searching, flexible episode selection, resolution preference, server choice, and subtitle management.

> [!NOTE]
> This script is designed to work with a running instance of the Zen API. Ensure you have access to such an instance before using this script. See the [Configuration](#️-configuration) section for details on setting the API URL.

## ✨ Features

* **Anime Discovery:**
  * Search for anime by name.
  * Select from search results using an interactive `fzf` menu with detailed previews.
  * Alternatively, specify anime directly by its Zen API ID.
* **Flexible Episode Selection:**
  * Download single episodes, multiple specific episodes, ranges, or all available.
  * Exclude specific episodes or ranges.
  * Select the latest 'N', first 'N', from 'N' onwards, or up to 'N' episodes.
  * Combine selection criteria (e.g., "1-10,!5,L2").
  * Interactive prompt for episode selection if not provided via command-line.
* **Download Customization:**
  * Choose preferred audio type (subbed or dubbed).
  * Specify preferred resolution via keywords (e.g., "1080", "720") to select the M3U8 variant stream.
  * Specify preferred server via keywords (e.g., "HD", "Vidstream") to filter server choices.
  * If no resolution preference is given, selects the highest bandwidth M3U8 variant stream by default.
* **Subtitle Management:**
  * Default behavior: Downloads the subtitle track marked as "default" by the API, or falls back to an "English" subtitle if available.
  * `-L <langs>`: Option to specify preferred subtitle languages (e.g., "eng,spa,jpn").
  * `-L all`: Option to download all available subtitles (of `kind: "captions"`).
  * `-L none`: Option to download no subtitles.
* **Efficient Downloading:**
  * Parallel segment downloads using GNU Parallel for faster HLS stream processing.
  * Configurable number of download threads (`-t <num>`).
  * Optional timeout for individual segment downloads (`-T <secs>`).
* **User Experience:**
  * Colorized and informative terminal output.
  * Debug mode (`-d`) for verbose logging.
  * Option to list stream links without downloading (`-l`).
  * Organized video downloads into `~/Videos/ZenAnime/<Anime Title>/` by default (configurable via `ZEN_DL_VIDEO_DIR`).

## Prerequisites

Before you can use `zen-dl.sh`, you need the following command-line tools installed on your system:

* **`bash`**: Version 4.0 or higher recommended.
* **`curl`**: For making HTTP requests to the API and downloading files.
* **`jq`**: For parsing JSON responses from the API.
* **`fzf`**: For interactive selection menus.
* **`ffmpeg`**: For concatenating downloaded HLS video segments.
* **`GNU Parallel`**: For parallel downloading of HLS segments.
* **`mktemp`**: For creating temporary directories. (core utils)

<br/>

> [!TIP]
> You can usually install these dependencies using your system's package manager.

<details>
<summary>Installing Dependencies</summary>

You can install the required dependencies using your system's package manager. Below are the commands for popular Linux distributions:

### Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y bash curl jq fzf ffmpeg parallel 
```

### Fedora

```bash
sudo dnf install -y bash curl jq fzf ffmpeg parallel 
```

### Arch Linux

```bash
sudo pacman -Syu bash curl jq fzf ffmpeg parallel 
```

</details>

## 🚀 Installation

1. **Download the script:**
    Save the script content as `zen-dl.sh` in your desired location.

    ```bash
    # using curl:
    curl -o zen-dl.sh https://raw.githubusercontent.com/ruxartic/zen-anime-dl/refs/heads/main/zen-dl.sh

    # using git (clone the repo):
    git clone https://github.com/ruxartic/zen-anime-dl.git
    cd zen-anime-dl
   ```

2. **Make the script executable:**

    ```bash
    chmod +x zen-dl.sh
    ```

3. **(Optional) Place it in your PATH:**
    For easier access from anywhere, move or symlink `zen-dl.sh` to a directory in your local `PATH`, like `~/.local/bin/`:

    ```bash
    ln zen-dl.sh ~/.local/bin/zen-dl
    ```

    Or add its directory to your `PATH` environment variable in your shell's configuration file (e.g., `~/.bashrc`, `~/.zshrc`).

## ⚙️ Configuration

The script determines the Zen API URL in the following order of precedence:

1. **Environment Variable `ZEN_API_URL`**: If the `ZEN_API_URL` environment variable is set and not empty, its value will be used. This is the recommended way to configure a custom API endpoint.

    ```bash
    # Example for your shell session:
    export ZEN_API_URL="https://my-custom-zen-api.example.com/api"
    # Then run the script:
    ./zen-dl.sh -a "Some Anime" 
    ```

    To make this permanent, add the `export` line to your shell's startup file (e.g., `~/.bashrc`, `~/.zshrc`, `~/.profile`).

2. **Script's Default `_DEFAULT_ZEN_API_BASE_URL`**: If `ZEN_API_URL` is not set or is empty, the script will use the value of `_DEFAULT_ZEN_API_BASE_URL` defined near the top of the `zen-dl.sh` file.

> [!IMPORTANT]
> The script won't work if neither the `ZEN_API_URL` environment variable is set (or is empty) NOR the `_DEFAULT_ZEN_API_BASE_URL` variable within the script points to a valid Zen API instance.

**Other Configuration:**

* **`ZEN_DL_VIDEO_DIR`**: Environment variable to set the root directory where downloaded anime will be saved.
  * Default if unset: `"$HOME/Videos/ZenAnime"`
  * Example: `export ZEN_DL_VIDEO_DIR="$HOME/MyAnimeCollection"`

## 📖 Usage

```
./zen-dl.sh [OPTIONS]
```

**Common Options:**

```
Mandatory (one of these):
  -a <anime_name>        Anime name to search for (ignored if -i is used).
  -i <anime_id>          Specify anime ID directly.

Episode Selection:
  -e <selection>         Episode selection string. Examples:
                         - Single: "1"
                         - Multiple: "1,3,5"
                         - Range: "1-5"
                         - All: "*"
                         - Exclude: "*,!1,!10-12" (all except 1 and 10-12)
                         - Latest N: "L3" (latest 3 available)
                         - First N: "F5" (first 5 available)
                         - From N: "10-" (episode 10 to last available)
                         - Up to N: "-5" (episode 1 to 5)
                         - Combined: "1-10,!5,L2" (1-10 except 5, plus latest 2)
                         If omitted, the script will list available episodes and prompt for selection.

Download Preferences:
  -r <res_keyword>       Optional, keyword for resolution in server name (e.g., "1080", "720").
                         Also used to select M3U8 variant stream.
  -S <server_keyword>    Optional, keyword for preferred server (e.g., "HD-1", "HD-2").
  -o <type>              Optional, audio type: "sub" or "dub". Default: "sub".
  -L <langs>             Optional, subtitle languages (comma-separated codes like "eng,spa",
                         or "all", "none", "default"). Default: "default".

Performance & Output:
  -t <num_threads>       Optional, number of parallel threads for segment downloads. Default: 4.
  -T <timeout_secs>      Optional, timeout for individual segment download jobs.
  -l                     Optional, list m3u8/mp4 links without downloading videos.
  -d                     Enable debug mode for verbose output.
  -h | --help            Display the help message.
```

For a full list of options, run:

```bash
./zen-dl.sh --help
```

### Examples

* **Search for "Frieren" and download episode 1 (default audio: sub, default subtitle behavior):**

    ```bash
    ./zen-dl.sh -a "Frieren" -e 1
    ```

* **Download episodes 5 to 10 and the latest 2 of an anime with ID `anime-xyz`, dubbed audio:**

    ```bash
    ./zen-dl.sh -i "anime-xyz" -e "5-10,L2" -o dub
    ```

* **Download episodes 1-5 using 8 threads for faster downloading:**
    ```bash
    ./zen-dl.sh -a "Anime Title" -e "1-5" -t 8
    ```

* **Download all episodes of "My Favorite Anime" except ep 3, prefer 720p, Spanish subs:**

    ```bash
    ./zen-dl.sh -a "My Favorite Anime" -e "*,!3" -r 720 -L spa
    ```

* **List stream links for episode 1 of "Another Anime" without downloading:**

    ```bash
    ./zen-dl.sh -a "Another Anime" -e 1 -l
    ```

* **Download all available subtitles for episode 1 of "Anime Name":**

    ```bash
    ./zen-dl.sh -a "Anime Name" -e 1 -L all
    ```

* **Download no subtitles for episode 1:**

    ```bash
    ./zen-dl.sh -a "Anime Name" -e 1 -L none
    ```


## 🛠️ How It Works

1. **Initialization**: Sets API URL (from `ZEN_API_URL` env var or script default) and checks dependencies.
2. **Anime Identification**:
    * Uses `-a <name>` to search via `/api/search`, then `fzf` for selection.
    * Uses `-i <id>` directly.
3. **Episode List Retrieval**: Fetches via `/api/episodes/{anime_id}`.
4. **Episode Selection Parsing**: Parses the `-e <selection>` string or prompts user.
5. **Stream Details Acquisition (for each episode):**
    * Gets server list from `/api/servers/{episode_stream_id}`.
    * Filters servers by user preferences (`-S`, `-o`).
    * Gets stream info (M3U8/MP4 URL, subtitles) from `/api/stream` using the chosen server.
6. **M3U8 Handling (HLS):**
    * Downloads master M3U8.
    * Parses it to find quality variants.
    * Selects variant by `-r <res_keyword>` or highest bandwidth.
    * Downloads the selected media M3U8 (containing segment URLs).
7. **Downloading**:
    * HLS segments are downloaded in parallel using GNU Parallel.
    * Direct MP4s are downloaded.
    * Subtitles are downloaded based on `-L <langs>` preference.
8. **Assembly (HLS)**: `ffmpeg` concatenates segments into a single `.mp4` file.
9. **File Organization**: Saves files to `VIDEO_DIR_PATH/ANIME_TITLE/Episode_NUM_TITLE.mp4`.
10. **Cleanup**: Temporary files and directories are removed after download completion.


<br/>

## 📜 Disclaimer

> [!WARNING]
> Downloading copyrighted material may be illegal in your country. This script is provided for educational purposes and for use with legitimately accessed API instances. Please respect copyright laws and the terms of service of any API provider. Use this script at your own responsibility.

## 🤝 Contributing

Contributions are welcome! If you have suggestions, bug fixes, or feature requests, please open an issue or submit a pull request.

## 📜 License

This project is licensed under the [MIT License](LICENSE).
