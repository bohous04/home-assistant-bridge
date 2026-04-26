# Instalace macbook-ha-bridge — návod pro úplného amatéra

Tento návod tě krok za krokem provede instalací malého programu, který do Home Assistanta posílá dva údaje o tvém Macu:

- `sensor.<prefix>_active_display` — jméno aktivního displeje (kde je menu bar). Např. `Built-in` nebo `LG HDR 4K`.
- `binary_sensor.<prefix>_locked` — `on` když máš obrazovku zamčenou (lock screen), `off` když odemčenou.

Program běží na pozadí (jako služba), startuje sám po přihlášení do Macu a updatuje hodnoty každé 2 vteřiny.

---

## Co budeš potřebovat

1. **Mac** s macOS (Apple Silicon i Intel — funguje na obou).
2. **Home Assistant** dostupný v tvojí síti (např. `http://homeassistant.local:8123` nebo přes IP).
3. **Soubory projektu** (tahle složka, kterou čteš).
4. **15 minut** času.

Žádný Xcode, Homebrew ani jiný nástroj instalovat nemusíš — Mac má všechno, co je potřeba.

---

## Krok 1 — Zkontroluj, že máš Command Line Tools

Ty jsou potřeba pro kompilaci Swift kódu. Otevři **Terminal** (Cmd+Space → napiš `Terminal` → Enter) a do něj napiš:

```bash
xcode-select -p
```

Pokud uvidíš něco jako `/Library/Developer/CommandLineTools` nebo `/Applications/Xcode.app/...`, máš hotovo, jdi na krok 2.

Pokud uvidíš `xcode-select: error: unable to get active developer directory`, pusť:

```bash
xcode-select --install
```

Vyskočí dialog, klikni **Install** a počkej (může to trvat několik minut). Až to doběhne, pokračuj krokem 2.

---

## Krok 2 — Vytvoř si v Home Assistantu Long-Lived Access Token

1. Otevři Home Assistant v prohlížeči.
2. Vlevo dole klikni na **svoje jméno** (profil).
3. Nahoře přepni na záložku **Security** (Zabezpečení).
4. Scrolluj úplně dolů na sekci **Long-Lived Access Tokens**.
5. Klikni **Create Token**.
6. Pojmenuj ho třeba `macbook-ha-bridge` a klikni **OK**.
7. **DŮLEŽITÉ:** Token se zobrazí jen **jednou**. Hned ho zkopíruj (Cmd+C) a ulož někam dočasně (TextEdit, lepidlo, cokoliv) — za chvíli ho zapíšeš do configu. Po zavření okýnka už ho znovu neuvidíš.

Token vypadá jako dlouhý řetězec znaků, např. `eyJhbGciOiJIUzI1NiIsInR5...` — má cca 200 znaků.

---

## Krok 3 — Zjisti URL svého Home Assistanta

Většinou je to jedno z:

- `http://homeassistant.local:8123` (default — funguje, pokud máš normální HA setup a tvůj Mac vidí HA přes mDNS)
- `http://192.168.x.y:8123` (IP HA — najdeš v routeru nebo v HA → Settings → System → Network)
- `https://tvoje-domena.cz` (pokud máš HA za reverse proxy s HTTPS)

Doporučení: **začni s `http://homeassistant.local:8123`**. Pokud nepojede, zkus IP.

Test, že HA odpovídá (v Terminalu):

```bash
curl http://homeassistant.local:8123
```

Měl bys dostat HTML stránku přihlašovacího okna HA. Pokud `Could not resolve host`, zkus IP adresu HA.

---

## Krok 4 — Přejdi do složky s projektem

V Terminalu napiš:

```bash
cd ~/Downloads/ha_script
```

(Uprav cestu, pokud máš soubory jinde. Nezapomeň na uvozovky, pokud cesta obsahuje mezery: `cd "~/Downloads/files (1)"`.)

Ověř, že tam jsou tyhle soubory:

```bash
ls
```

Měl bys vidět: `main.swift`, `install.sh`, `config.json`, `config.example.json`, `cz.lnrt.macbook-ha-bridge.plist`, `installation.md`, `README.md`.

---

## Krok 5 — Vyplň config.json

Otevři `config.json` v editoru:

```bash
open -e config.json
```

(Otevře to v TextEditu. Můžeš použít i `nano config.json` přímo v Terminalu, pokud TextEdit přidává formátování.)

Soubor vypadá takhle:

```json
{
  "haURL": "http://homeassistant.local:8123",
  "token": "VLOZ_SEM_LONG_LIVED_ACCESS_TOKEN_Z_HOME_ASSISTANT",
  "entityPrefix": "muj_macbook",
  "deviceName": "Můj MacBook",
  "pollInterval": 2.0,
  "heartbeatInterval": 60.0
}
```

Vyplň:

- **`haURL`** — URL tvého HA z kroku 3.
- **`token`** — token z kroku 2 (zkopíruj celý dlouhý řetězec).
- **`entityPrefix`** — technické jméno, které se objeví v entity_id v HA. **Bez mezer, diakritiky a velkých písmen.** Jen `[a-z0-9_]`. Např. `michals_macbook` → entity budou `sensor.michals_macbook_active_display` atd.
- **`deviceName`** — hezké jméno, které se zobrazí jako `friendly_name` v HA UI. Může mít mezery, apostrofy, češtinu. Např. `"Michalův MacBook"` nebo `"Michal's MacBook Pro 14"`.
- **`pollInterval`** — jak často (v sekundách) program čte stav. `2.0` je rozumné.
- **`heartbeatInterval`** — jak často (v sekundách) povinně pushne stav, i když se nezměnil. `60.0` znamená "každou minutu". Slouží k tomu, aby HA poznal, že je Mac online (stálé updaty `last_updated`).

Příklad vyplněného configu:

```json
{
  "haURL": "http://192.168.0.45:8123",
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOi...",
  "entityPrefix": "michals_macbook",
  "deviceName": "Michalův MacBook",
  "pollInterval": 2.0,
  "heartbeatInterval": 60.0
}
```

Ulož soubor (Cmd+S v TextEditu, nebo Ctrl+O → Enter → Ctrl+X v nano).

---

## Krok 6 — Pusť instalaci

Pořád v té samé složce v Terminalu napiš:

```bash
chmod +x install.sh
./install.sh
```

Mělo by to vypsat něco jako:

```
==> Build
==> Config
    Zkopírováno .../config.json → .../macbook-ha-bridge/config.json
==> launchd plist
==> Reload agent

Hotovo. Logy: /Users/tvoje_jmeno/Library/Logs/macbook-ha-bridge.log
```

Pokud uvidíš chybu, koukni dolů do sekce **Časté problémy**.

---

## Krok 7 — Ověř, že to běží

### Zkontroluj log

```bash
tail -f ~/Library/Logs/macbook-ha-bridge.log
```

Měl bys vidět:

```
[state] active=Built-in locked=false
[start] macbook-ha-bridge running, poll=2.0s heartbeat=60.0s
```

A **žádné** řádky obsahující `[ha] error` nebo `[ha] HTTP 4xx/5xx`. Stiskni **Ctrl+C** pro vystoupení z `tail`.

> **Pozn.:** Pokud při úplně prvním startu vidíš `[ha] ... The Internet connection appears to be offline.`, je to známý transient bug — launchd občas spustí program dřív, než je síť úplně ready. Pojistka:
>
> ```bash
> launchctl kickstart -k "gui/$(id -u)/cz.lnrt.macbook-ha-bridge"
> ```
>
> Restartuje agent. Druhý běh by měl být čistý.

### Zkontroluj entity v Home Assistant

V HA jdi na **Developer Tools** (vlevo dole, ikona kladívka) → **States**. Do filtru napiš svůj prefix (např. `michals_macbook`). Měl bys vidět:

| Entity | State | Friendly name |
|---|---|---|
| `sensor.michals_macbook_active_display` | `Built-in` | Michalův MacBook Active Display |
| `binary_sensor.michals_macbook_locked` | `off` | Michalův MacBook Locked |

Když zamkneš obrazovku (Ctrl+Cmd+Q), `binary_sensor...locked` přepne na `on` do 2 vteřin. Když odemkneš, vrátí se na `off`.

Když připojíš externí monitor a přesuneš na něj menu bar (System Settings → Displays → drag the white bar to the external display), `sensor...active_display` ukáže jméno toho monitoru (např. `LG HDR 4K`).

---

## Co se vlastně nainstalovalo

| Co | Kam |
|---|---|
| Binary | `~/.local/bin/macbook-ha-bridge` |
| Launchd plist (autostart) | `~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist` |
| Config | `~/.config/macbook-ha-bridge/config.json` |
| Log | `~/Library/Logs/macbook-ha-bridge.log` |

**Nikde se nesahalo do systému** — vše je v tvém home adresáři, žádné `sudo`, žádné systémové změny.

Program startuje automaticky po přihlášení do Macu (`RunAtLoad=true`) a launchd ho vždycky restartuje, když by spadl (`KeepAlive=true`).

---

## Časté operace

### Restart agenta (po změně configu)

Když upravíš `config.json` v projektové složce, pusť `./install.sh` znovu — zkopíruje nový config a restartne agent.

Když upravíš `~/.config/macbook-ha-bridge/config.json` přímo, restart manuálně:

```bash
launchctl kickstart -k "gui/$(id -u)/cz.lnrt.macbook-ha-bridge"
```

### Zastavit agent

```bash
launchctl bootout "gui/$(id -u)/cz.lnrt.macbook-ha-bridge"
```

### Spustit znovu (po bootout)

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist
```

### Sledovat log v reálném čase

```bash
tail -f ~/Library/Logs/macbook-ha-bridge.log
```

---

## Časté problémy

### `swiftc: command not found` při buildu

Chybí Xcode Command Line Tools. Pusť:

```bash
xcode-select --install
```

A po instalaci pusť `./install.sh` znovu.

### `[ha] ... The Internet connection appears to be offline.`

Transient bug launchd × URLSession. Restart agenta:

```bash
launchctl kickstart -k "gui/$(id -u)/cz.lnrt.macbook-ha-bridge"
```

Pak zkontroluj log — druhý běh by měl být bez errorů.

### `[ha] ... HTTP 401`

Špatný token (nebo expirovaný). Vygeneruj v HA nový (krok 2) a zapiš ho do `config.json`. Pak `./install.sh` znovu.

### `[ha] ... HTTP 404`

URL `haURL` v configu je špatná (HA tam neposlouchá). Ověř kroky 3 (HA URL) a 5 (config).

### `Cannot read config at /Users/.../macbook-ha-bridge/config.json`

Config se nezkopíroval. Pusť `./install.sh` z projektové složky znovu (ujisti se, že tam je `config.json` vyplněný).

### `Invalid config: ... missingValue`

Config existuje, ale chybí v něm některé pole. Otevři `~/.config/macbook-ha-bridge/config.json` a zkontroluj, že obsahuje **všech 6** klíčů: `haURL`, `token`, `entityPrefix`, `deviceName`, `pollInterval`, `heartbeatInterval`. Doporučení: vrať se ke kroku 5 a vyplň `config.json` v projektové složce, pak pusť `./install.sh` znovu.

### Entity v HA nevidím

1. Daemon běží? `pgrep -fl macbook-ha-bridge` — měl by vrátit pid + cestu.
2. V logu nejsou errory? `tail ~/Library/Logs/macbook-ha-bridge.log`
3. URL i token v configu jsou správné? Test:
   ```bash
   curl -H "Authorization: Bearer TVUJ_TOKEN" http://homeassistant.local:8123/api/
   ```
   Měl by vrátit `{"message":"API running."}`. Pokud ne, problém je v configu.
4. Filtruješ správně? V HA → Developer Tools → States hledej `<entityPrefix>_` (s podtržítkem na konci).

### `homeassistant.local` se neresolvuje

Tvoje síť/router neposkytuje mDNS. Použij IP adresu HA (`http://192.168.x.y:8123`) — najdeš v routeru nebo přímo v HA → Settings → System → Network.

---

## Odinstalace

```bash
launchctl bootout "gui/$(id -u)/cz.lnrt.macbook-ha-bridge"
rm ~/Library/LaunchAgents/cz.lnrt.macbook-ha-bridge.plist
rm ~/.local/bin/macbook-ha-bridge
rm -rf ~/.config/macbook-ha-bridge
rm ~/Library/Logs/macbook-ha-bridge.log
```

V HA pak entity smažeš přes Developer Tools → States, najdi entitu, klikni dole na **Set State** s prázdnou hodnotou a smaž, nebo přes REST API:

```bash
curl -X DELETE -H "Authorization: Bearer TVUJ_TOKEN" \
  http://homeassistant.local:8123/api/states/sensor.michals_macbook_active_display
curl -X DELETE -H "Authorization: Bearer TVUJ_TOKEN" \
  http://homeassistant.local:8123/api/states/binary_sensor.michals_macbook_locked
```

(Nahraď `michals_macbook` svým prefixem.)
