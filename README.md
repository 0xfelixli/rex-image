# rex-image

Paste clipboard images into a remote Codex CLI session through your **existing Rex connection**, including Rex's built-in Tailscale node. No SSH, extra network listener, Python, or remote installation is required.

**One Lua file. Install it on the Mac running the Rex app.**

## How it works

- **Text → paste directly.** Text never enters the image queue, waits for an upload, or rewrites the clipboard.
- **Image → upload in the background, then paste its remote path into the original terminal.** Nothing presses Enter or submits a message.
- Existing PNG, JPEG, GIF and WebP clipboard data is reused. Other image representations are converted to PNG.
- Transfers reuse one Rex CLI connection and one detached receiver block. The receiver does not appear as a tab.
- Frames stay below Rex's 64 KiB control-message limit. Acknowledgements, byte counts and SHA-256 verify delivery.
- Repeated remote images reuse a verified content-addressed cache.
- Image jobs are serialized with an OS advisory lock; ordinary text bypasses that lock.

The script uses macOS's bundled AppKit, Perl and command-line tools. The remote receiver uses Perl, `MIME::Base64`, `Digest::SHA` and POSIX terminal handling, tested on macOS.

## Install on the client Mac

For an **Air → mini** setup, install on **Air**, not mini.

1. Download [`rex-paste.lua`](rex-paste.lua) into `~/.config/rex/rex-paste.lua`.
2. Add this line **once** to your existing `~/.config/rex/init.lua`:

   ```lua
   require("rex-paste")
   ```

3. Check and reload from a **local terminal on the client Mac**:

   ```sh
   "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" config check
   "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" config reload
   ```

If Rex is installed elsewhere, update `CLI` near the top of the Lua file.

The script uses the current Rex session's server; there is no hard-coded hostname or session ID. That server must also be resolvable by the client's Rex CLI. Confirm your remote host appears in `rex hosts --json`.

## Use

1. On the client Mac, press **Control + Shift + Command + 4** to copy a screenshot to the clipboard, or copy an image from an application.
2. Focus the remote Codex CLI terminal in Rex.
3. Press **Command + V** once.
4. Wait for the notification and image attachment/path in Codex, then add your prompt and submit it yourself.

Copy and paste text normally. Image uploads do not replace the clipboard contents. A local Rex terminal uses a local file instead of uploading.

Finder file-copy/drag-and-drop uploads are not implemented. If a clipboard contains both text and an image, **text takes priority**. Clipboard image formats offered by individual applications can differ.

## Limits and behaviour

- Maximum image size: **20 MiB**; images are not resized or made lossy.
- This wraps terminal `Command + V`, so reading the clipboard still adds some overhead compared with native text paste. Image work does not block the text path.
- Large text pastes are divided into UTF-8-safe paste events to respect Rex's message limit; an agent may group these events differently from a single native paste.
- An upload is cancelled at the paste stage if the original terminal's process changed while queued or transferring. It never falls back to another focused tab.
- A transfer times out after inactivity; it has no automatic resume/retry. Retry by pasting again.
- Image jobs are serialized, but strict FIFO ordering between simultaneously launched jobs is not guaranteed by the OS lock.
- Remote images are stored in `~/.cache/rex-paste/`. Hash-named remote cache files older than **30 days** are removed during later remote uploads. Do not rely on this cache as permanent storage for old conversations.
- Local image cache files are retained until manually removed. Temporary clipboard snapshots are removed after the worker finishes; an abrupt crash may leave temporary files for the OS to clean up.
- Logs rotate at approximately 1 MiB, retaining one previous log. Logs contain image paths and transfer metadata, not image contents or copied text.
- Rex's CLI and Lua APIs are beta APIs. Compatibility may change between versions.

## Troubleshooting

Read the log on the **client Mac**:

```sh
cat ~/.cache/rex-paste/upload.log
```

If no log appears, search Rex's command palette for **Paste Text or Remote Image** and run it. Check for app-level shortcut overrides: Rex's **Change Shortcut…** bindings take priority over configuration-file bindings.

If a host name cannot be resolved, check `rex hosts --json` on the client Mac. This is separate from whether the GUI can display a remote session.

For `Target process changed`, focus the intended Codex prompt and paste again. For an upload that is queued indefinitely, inspect running Rex CLI/Perl workers rather than deleting the lock file: the lock is released automatically when its holder exits.

## Uninstall

Remove `require("rex-paste")` from `init.lua` and run `rex config reload`. This removes this module's shortcut bindings. You can then delete `rex-paste.lua`; cache files may be removed separately when no longer needed.

## Verification

Tested on macOS with Rex's installed Lua/CLI interfaces:

- Clipboard PNG extraction, queued background processing and targeted paste.
- Chinese multiline text pasted while the image queue was deliberately blocked.
- A 104 KB Unicode multiline paste, with all 8,000 repeated lines retained.
- 1 MiB and 3 MiB transfers with byte-for-byte comparison, plus cache hits.
- Corrupt-transfer rejection, changed-target rejection and receiver-block cleanup.

The earlier implementation was also used successfully to attach an Air clipboard image to Codex on mini. This optimized version has been tested locally through Rex; its full Air-to-mini cross-network path still needs separate verification.

Local transfer-only measurements, **not network benchmarks**:

| Payload | Earlier implementation | Current implementation | Current cache hit |
| --- | ---: | ---: | ---: |
| 1 MiB | 0.94 s | 0.33 s | 0.11 s |
| 3 MiB | 2.34 s | 0.65 s | 0.12 s |

## References

- [Rex documentation](https://www.superlogical.com/rex/docs)
- [Rex Lua API](https://www.superlogical.com/rex/docs/reference/lua)
- [Herdr clipboard/upload implementation](https://github.com/herdrdev/herdr-app/blob/master/src/terminal.rs), which informed the user experience. This project uses Rex APIs, not Herdr's `terminal.put` API.

## 中文快速说明

这是一个装在 **Air 客户端**上的 Rex Lua 插件。连接 mini 后，在远程 Codex CLI 按一次 `Cmd+V`，剪贴板图片会通过现有 Rex/Tailscale 连接上传，并将图片路径粘贴到原终端，不自动回车。

普通文字走独立路径，不进图片队列，不等待上传，不修改剪贴板。安装只需放置一个 Lua 文件，在 Air 的 `init.lua` 中加入 `require("rex-paste")`，再检查和重载配置。此版本的跨网络完整流程仍需实测。

## License

MIT.
