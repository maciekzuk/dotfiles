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
| `done`    | Stop         | zielony `#87d787`   | skończył, gotowe  |
| `waiting` | Notification | pomarańcz `#ffaf5f` | czeka na Ciebie   |

Jedna flaga `@claude-state`, ostatnie zdarzenie wygrywa. Kropka na **końcu**
wpisu okna (`#I #W ●`). Wejście w okno czyści oba stany.

## Komponenty

### `scripts/claude-tmux-notify.sh` (nowy)
POSIX sh. Argument `done|waiting` (domyślnie `done`). Guardy: `$TMUX`,
`$TMUX_PANE`. Pomija `window_active=1`. `tmux set -w -t "$TMUX_PANE"
@claude-state "$state"` + `tmux refresh-client -S`.

### `tmux.conf` (zmiana)
- `window-status-format` + warunkowa kropka:
  `#I #W#{?@claude-state, #{?#{==:#{@claude-state},waiting},#[fg=#ffaf5f],#[fg=#87d787]}●#[fg=#4e4e4e],}`
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
3. Realnie: Claude w pane w tle kończy → `●`; permission prompt → pomarańcz `●`.

## Addendum (2026-06-16) — kolory, skip, cross-session

Po zatwierdzeniu designu doszły trzy zmiany:

1. **Kolory:** `done` = zielony `#87d787`, `waiting` = pomarańcz `#ffaf5f`
   (paleta jak color-pct: green/orange/red).
2. **Skip logic:** kropkę pomijamy tylko gdy *realnie patrzysz* na pane —
   `window_active=1 ORAZ session_attached≥1`. Sam `window_active` był błędny:
   każda **odpięta** sesja ma swoje aktywne okno (`active=1`), więc Claude
   kończący tam nigdy nie dostawał flagi. Teraz odpięte sesje dostają kropkę.
3. **Cross-session notyfikacja (styl terminalowy):** kropka żyje tylko w
   liście okien *bieżącej* sesji, więc hook dodatkowo robi **flash w
   status-barze** (`tmux display-message -c <client>`) na **każdym podpiętym
   kliencie**, z treścią `sesja:okno`. Widać go niezależnie od tego, w której
   sesji siedzisz. Świadomie odrzucone: macOS-owe banery (osascript /
   terminal-notifier) — user chce notyfikacji terminalowej, nie GUI.
   Powiadomienie leci **zawsze** (niezależnie od skip kropki).

## Addendum 2 (2026-06-16) — wskaźnik przy sesji + kolory w sesh

Kropka żyje tylko w liście okien *bieżącej* sesji, więc doszły dwa sygnały
oparte o tę samą flagę `@claude-state` (skan `tmux list-windows -a`):

1. **Wskaźnik w `status-left`** (`scripts/claude-other-sessions.sh '#{client_session}'`)
   — pojedyncza kropka obok nazwy sesji, gdy **inna** sesja (≠ bieżąca) ma
   zaległego Claude'a. Pomarańcz jeśli gdziekolwiek `waiting`, inaczej zielony.
   User wybrał "sama kropka" (nie nazwy/licznik).
2. **Kolory w pickerze `sesh`** (`scripts/sesh-list-claude.sh`, binding `prefix+s`)
   — `sesh list -t` przepuszczone przez kolorowanie ANSI (215=#ffaf5f,
   114=#87d787). `fzf --ansi` zdejmuje kody z wyniku, więc `sesh connect`
   dostaje czystą nazwę (zweryfikowane). Mapa stanów + lista sesh idą jednym
   pipe'em do awk (rozdzielone markerem) — `awk -v` nie bierze wieloliniowych.

Uwaga testowa: `display-message -p '#(...)'` NIE nadaje się do testu widgetów
`#()` (nie czeka na job w tle — daje pusto nawet dla działającego `vpn.sh`).
Weryfikacja przez analogię do istniejących widgetów + standalone.

Potwierdzenie na żywo: realny Claude w `ediets:3` odpalił hook `Notification`,
flaga `waiting` ustawiła się na właściwym oknie (czyli hook + `$TMUX_PANE`
działają end-to-end).
