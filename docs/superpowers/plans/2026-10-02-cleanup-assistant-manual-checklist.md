# Cleanup Assistant — manual end-to-end checklist

Not run (needs a GUI plus real Ollama Cloud / local Ollama / LM Studio servers). Build and install with `./scripts/install-local-debug.sh` (Debug configuration, so the license bypass applies and the Full Disk Access grant survives rebuilds).

Privacy rule these checks rely on (`AssistantSettings.sendsDataOffDevice`): **Ollama Cloud is always treated as off-device, whatever the URL** (redacted paths + disclosure sheet). Only «Локальная Ollama» and «OpenAI-совместимый» have the loopback exemption: with a host of `localhost`, `127.0.0.1` or `::1` they send full paths and show no disclosure; with any other host they are redacted and gated like the cloud.

### Preconditions / reset

Quit the app first, then reset the assistant state you want to start from (all of these are the human's own local data):
```
defaults delete com.spotlessmac.app assistantCloudDisclosureAccepted   # disclosure shows again on the next off-device send
defaults delete com.spotlessmac.app assistantSettings                  # provider/URL/model/tool mode/timeout back to defaults
defaults delete com.spotlessmac.app assistantToolSupport               # forget the per-model "supports tools" cache
security delete-generic-password -s com.spotlessmac.app -a assistantAPIKey   # remove the saved API key from the Keychain
rm ~/Library/Application\ Support/SpotlessMac/assistant-conversation.json    # drop the saved conversation
```
Each command errors harmlessly if the item does not exist. Reset between provider scenarios as needed (A1 needs the disclosure flag cleared; A4/A7 need the tool-support cache cleared).

What each item needs in addition:
- A completed scan before the snapshot and plan items exist: A1, A3, A4, B10, C12-C14, E21. For A1 the scan should find something under a personal folder such as `~/Documents/<project>` or `~/MyProjects/<project>`, so redaction has something to alias.
- A selected app with leftovers («Программы» -> select an app): E22.
- Docker Desktop running with at least one image, container or volume: E23.
- A real Ollama Cloud token: A1 (any token string is enough for A6 and D18). A local Ollama server: A2, A3, A4, A6, A7. LM Studio with a model loaded: A5.

### A. Providers and privacy

1. **Ollama Cloud redaction, with the brief's `nc` procedure (works as written).** Reset the disclosure flag (above). Settings -> «АССИСТЕНТ»: provider «Ollama Cloud», model `gpt-oss:20b`, a token, URL changed to `http://localhost:9999`, «Сохранить». In a terminal run `nc -l 9999`. In the Assistant tab send any question (e.g. «Почему диск заполнен?»).
   - Expected: the disclosure sheet appears first (even though the URL is `localhost`, because Ollama Cloud is always off-device); «Понятно» sends; `nc` prints the `POST /api/chat` request body. In the body there must be no `/Users/<your-name>` (home appears as `~`), no real project/document folder names (they appear as `<папка-N>`), and no non-default volume name (it appears as «системный диск»). The model's reply never arrives (nc does not answer): press «Стоп» or wait for the timeout. Then restore the URL to `https://ollama.com` and save.
   - Then, with the real URL and token, confirm the answer streams.
2. **Loopback exemption applies only to the other two providers.** Switch the provider to «Локальная Ollama», URL `http://localhost:9999`, `nc -l 9999`, send: expect no disclosure sheet and a body with the real home path. Optional: «Локальная Ollama» pointed at a LAN address (e.g. `http://192.168.x.x:11434`) behaves like the cloud (disclosure sheet, redacted body).
3. Local Ollama with a tool-capable model (e.g. `qwen3:8b`): «Освободи 5 ГБ безопасно» -> status line «Смотрю список найденного…» -> plan card.
4. Local Ollama with a model without tools (e.g. `gemma:2b`) in «Авто»: the answer arrives and the plan card comes from the `spotless-plan` text block; «Проверить подключение» reports «инструменты не поддерживаются, план будет текстовым».
5. LM Studio (OpenAI-compatible, `http://localhost:1234`): chat works without a token and without a disclosure sheet.
6. Errors: wrong token on Ollama Cloud -> «Неверный токен. Проверьте его в Настройки → Ассистент.» with a «Настройки» button; Ollama stopped -> «Не удалось подключиться к localhost:11434. Если это локальная Ollama — запустите приложение Ollama или `ollama serve`.»
7. «Проверить подключение» must never go green on a broken stream. Local Ollama selected, press «Проверить подключение» and immediately quit Ollama (or `pkill ollama`) while the check runs. Expected: a warning result with «Ответ прерван: соединение закрылось раньше времени.» (stream cut) or «Не удалось подключиться к localhost:11434…» (server already gone), never «Ответила <model> …». («Проверка отменена» is the message for a cancelled check task; the settings card does not cancel it, so you normally will not see it from the UI.)
8. «Повторить» after a failed answer while the provider has since been switched to Ollama Cloud with the disclosure flag reset: the disclosure sheet appears first and the failed message stays until the user decides.

### B. Conversation

9. Quit and relaunch -> the last conversation is restored; «Новый диалог» clears it (and the orange stale-plan notice, if one is showing).
10. «Почему диск заполнен?» shows plain text while streaming and switches to formatted markdown once complete; «Стоп» works; a link in model output is not clickable.
11. «Почему тормозит Mac?» mentions memory pressure / heaviest apps and suggests closing them in «Память» (never claims to close anything itself).

### C. Plan -> preview -> delete (the assistant must never delete anything)

12. Plan card -> «Открыть в превью» -> switches to «Диск» and opens «Освободить место» with the «Выбрано ассистентом» banner. Trash contents are unchanged until you press «Очистить выбранное» and confirm «Переместить в Корзину».
13. «Сбросить выбор» clears the selection and the banner; closing the sheet clears the banner.
14. Stale plan: after a rescan (or after relaunch with a persisted plan card), «Открыть в превью» keeps the current selection, stays on the Assistant tab and shows the orange notice «Список найденного изменился — попросите ассистента составить план заново.» above the composer; sending any message clears it.
15. *Optional — covered by unit tests.* A model attempting `delete_file` is refused and logged. The refusal is asserted in `AssistantToolboxTests` and `AssistantIsolationTests.testToolSetIsClosedAndReadOnly`; what is left is live-model behaviour and the `Logger` warning in Console.app (subsystem `com.spotlessmac.app`, category `assistant`), which needs a model that can be coaxed into calling an unknown tool.

### D. Wiring and settings

16. The rail shows «Помощь» (sparkles) as the last main tab, license/FDA badges are hidden on it, and it shows «Подключите модель» until configured. The Memory tab and the rail look right with 7 tiles.
17. Settings -> «АССИСТЕНТ» appears after «ОБЩИЕ»: switching provider changes URL/model; the token field is hidden for local Ollama; «Проверить подключение» shows a result; «Сохранить» / «Сбросить» work; the Assistant tab picks up saved settings.
18. Token isolation: with Ollama Cloud saved with a key, switch the segmented control to OpenAI-compatible -> the token field empties; switch back to Ollama Cloud -> the saved key returns.
19. **Product decision (not a pass/fail check):** Settings «Стартовый раздел» now offers «Ассистент»; the content is empty for one render until `.onAppear` creates the assistant. Decide whether it should stay selectable.
20. «Программы»: app sizing continues across tab switches and the list/selection is preserved when returning (hoisted `UninstallViewModel`); the «По размеру» toggle still works.

### E. «Спросить ассистента» entry points

21. «Диск» -> «Освободить место»: the ⓘ button appears on rows (confirms the environment value reaches the sheet). ⓘ on DerivedData: the sheet closes, the «Ассистент» tab opens, an answer about that item streams. The right-click entry «Спросить ассистента» works too. For an item whose owner (e.g. Xcode) is running, the answer mentions the owner app is open.
22. «Программы»: select an app, use ⓘ and right-click on a leftover row: the tab switches and the answer mentions the app name. Neither action toggles the row's checkbox unexpectedly.
23. «Docker»: ⓘ and the context menu on an image/container/volume row: the tab switches and an answer about that resource streams. ⓘ stays usable while a scan/delete runs.
24. Fresh install state (reset above; cloud default, no key): ⓘ on a row switches to «Ассистент» and shows «Подключите модель»; no disclosure sheet, and no message in the history after configuring.

## Knowledge base (2026-10-03)

Run each question twice — local Ollama with tools on, and with «Инструменты: Выкл» — on a Mac with a fresh scan and the «Память» tab opened once.

- [ ] «Что за процесс kernel_task и почему он грузит процессор?» — answer matches `proc.kernel-task`, no invented settings.
- [ ] «Почему Системные данные занимают так много?» — follows `guide.system-data`.
- [ ] «Как разобрать папку Загрузки?» — follows `guide.downloads-cleanup`, points to «Освободить место».
- [ ] «Можно удалить резервные копии iPhone?» — verdict «не трогать», points to Finder.
- [ ] «Chrome ест 6 ГБ памяти, что делать?» — follows `app.chrome`, mentions «Память».
- [ ] «Как убрать программы из автозагрузки?» — gives the «Объекты входа» path from `guide.login-items`.
- [ ] «Что такое mds_stores?» — tool mode calls `lookup_knowledge` (status «Читаю справку…»).
- [ ] Ask about something not in the base («как настроить принтер») — the assistant says it has no reference and answers cautiously.
- [ ] Cloud provider: request log contains article ids but no real home paths.
- [ ] Every answer above stays within the no-delete rules and contains no terminal commands.
