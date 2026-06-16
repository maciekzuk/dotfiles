# Claude window dot — design

Kropka w status-barze tmux przy oknie, w którym pane z Claude Code skończył
zadanie albo czeka na reakcję. Kropka znika po wejściu w okno.

## Cel

Gdy Claude pracuje w pane w tle, chcę bez przełączania okien wiedzieć, że:
- **skończył zadanie** (Stop), albo
- **czeka na moją reakcję** — pozwolenie / input (Notification).

Sygnał: mała `●` przy nazwie okna na liście okien. Po wejściu w okno znika.

## Mechanizm (event-driven, bez pollingu)

1. **Hooki Claude Code** (`~/.claude/settings.json`) odpalają skrypt:
   - `Stop`    → `claude-tmux-notify.sh done`
   - `Notification` → `claude-tmux-notify.sh waiting`
2. **Skrypt** czyta `$TMUX_PANE` (Claude zna swój pane), pomija aktywne okno
   (`window_active`), ustawia okienną opcję `tmux set -w @claude-state done|waiting`.
3. **`window-status-format`** pokazuje kropkę warunkowo z `#{?@claude-state,...}`
   (format liczony per-okno → flaga jest okienna).
4. **Hook tmux `pane-focus-in`** czyści flagę przy wejściu w okno → kropka znika.
   (`focus-events on` jest już ustawione.)

Odrzucone alternatywy: dzwonek terminala + `monitor-bell` (mało kontroli, hałas);
polling zawartości pane'ów (kruche).

## Stany i kolory (paleta Vesper)

| Stan      | Hook         | Kolor               | Znaczenie         |
|-----------|--------------|---------------------|-------------------|
| `done`    | Stop         | koral `#ff8080`     | skończył, gotowe  |
| `waiting` | Notification | żółty `#ffaf5f`     | czeka na Ciebie   |

Jedna flaga `@claude-state`, ostatnie zdarzenie wygrywa. Kropka na **końcu**
wpisu okna (`#I #W ●`). Wejście w okno czyści oba stany.

## Komponenty

### `scripts/claude-tmux-notify.sh` (nowy)
POSIX sh. Argument `done|waiting` (domyślnie `done`). Guardy: `$TMUX`,
`$TMUX_PANE`. Pomija `window_active=1`. `tmux set -w -t "$TMUX_PANE"
@claude-state "$state"` + `tmux refresh-client -S`.

### `tmux.conf` (zmiana)
- `window-status-format` + warunkowa kropka:
  `#I #W#{?@claude-state, #{?#{==:#{@claude-state},waiting},#[fg=#ffaf5f],#[fg=#ff8080]}●#[fg=#4e4e4e],}`
- `set-hook -g pane-focus-in 'set -uw @claude-state'`
- `window-status-current-format` bez zmian (aktywne okno nigdy nie dostaje flagi).

### `~/.claude/settings.json` (zmiana, poza repo)
Dopisać drugą komendę do `Stop` i nowy blok `Notification` (oba `async:true`).
Ścieżka `~/.tmux/scripts/...` rozwiązuje się przez symlink do dotfiles.

### `README.md` (zmiana)
Notka o feature + że wiring hooków żyje w `~/.claude/settings.json` (poza repo).

## Założenia / ograniczenia
- Hook dziedziczy `$TMUX_PANE` ze środowiska Claude'a — **weryfikacja to krok 1**;
  jeśli puste, fallback (np. parsowanie z `tmux list-panes`/PID).
- `window_active` rozróżnia okna w obrębie jednej sesji — wystarcza dla setupu
  jednego laptopa (jeden klient).
- Kilka pane'ów Claude w jednym oknie → wspólna flaga okna (ostatni wygrywa);
  akceptowalne.

## Weryfikacja
1. `$TMUX_PANE` dostępny w hooku (echo do pliku z hooka testowego).
2. Ręcznie: `tmux set -w -t <pane_w_tle> @claude-state done` → widać koral `●`.
   `... waiting` → żółta. Wejście w okno → znika.
3. Realnie: Claude w pane w tle kończy → `●`; permission prompt → żółta `●`.
