# NXNative para Mac

Aplicación de administración en SwiftUI para
[nxnative](https://github.com/MathiasKowoll/nxnative): construye tus juegos de
Switch como apps nativas de Mac (o IPA), los guarda en una biblioteca, ajusta
cada juego, los arranca y sigue su log.

Vive en `frontend/NXNativeMac` del fork, pero no toca nada de nxnative: usa
la interfaz que nxnative documenta para front ends (`docs/frontends.md`). Si
nxnative cambia esa interfaz, el punto de contacto está en `Sources/NXCore`.

> Juegos y claves son tuyos. La app no incluye ni descarga nada de ningún
> juego, y de `prod.keys` solo guarda la **ruta**: lee `header_key` para
> identificar archivos sin etiqueta (los valores no se muestran ni se
> registran) y el archivo entero se lo pasa al script con `-k`.

## Qué hace

| Pantalla | Qué hay |
|---|---|
| **Biblioteca** | Interfaz tipo consola con hero y carrusel de carátulas. Juegos, Ajustes, Registro, Partidas, Avanzado y Entorno se manejan dentro de la misma pantalla, con teclado, ratón y mando. |
| **Instalar FC26/FC27** | Flujo de un solo paso: eliges tu carpeta con NSP/NSZ/XCI/XCZ, tu `prod.keys` y el destino; el title ID detecta automáticamente FC26 o FC27 y ejecuta el builder correspondiente. El instalador incluye dentro de su propio `.app` la toolchain de nxnative, los perfiles, traductores de shaders y el builder de FC26. El resultado queda autocontenido con runtime, juego, módulos, shaders y launcher. No incluye ni redistribuye el juego ni las claves. |
| **Juegos en disco** | Base, actualizaciones y DLC agrupados por title ID, estén en una carpeta por juego o todos juntos con los DLC en subcarpetas. Dice si nxnative tiene perfil y avisa de un XCI que trae la actualización en el cartucho. Construye una app de Mac, una IPA o un build de desarrollo, con todas las opciones del script. Benchmark (`scripts/bench.py`) cuando el perfil tiene ruta. |
| **Construcciones** | Cola de builds de uno en uno, con etapas, progreso, ETA y la consola del script. Cancelar manda SIGINT (el script sale con 130 y deja lo reutilizable). |
| **Compatibilidad** | La tabla de `dm/games/README.md` cruzada con lo que tienes. Cada juego enlaza a su nota dentro de la toolchain incluida. |
| **Entorno** | Comprobaciones reales: Apple silicon, Metal 4 y arquitectura de la GPU, Python ≥ 3.12, `nsz`, Xcode, herramientas de build, versión del compilador de Metal contra `dmsh_chain.lock`, permisos de `prod.keys`, espacio libre. Mandos que ve macOS. |

El destino por defecto de las apps generadas se configura en **Entorno → Apps
generadas**. El instalador FC26/FC27 usa esa carpeta y la añade a la biblioteca;
el botón **Cambiar…** del instalador permite escoger una ubicación distinta
para una instalación puntual. Si la carpeta anterior contiene apps de juego,
NXNative pregunta si se deben mover al nuevo destino o conservarlas donde
están.

### Detalles que importan

- **Bibliotecas planas.** El script exige una carpeta por juego. Si los
  archivos de un juego comparten carpeta con otros o están repartidos, la app
  crea `<carpeta de juegos>/_nxnative/<nombre> [<title ID>]/` con **enlaces
  simbólicos**: no mueve ni renombra nada y no ocupa espacio. El nombre del
  enlace lleva `[title ID][vN]`, que es lo que lee el script cuando no hay
  ticket. Se pone al día antes de cada build. Comprobado contra el script
  real: la busca por el ticket y `nx_extract` abre el destino del enlace.
- **Title ID.** De un NSP/NSZ se lee el ticket de su PFS0 (gana a la etiqueta
  del nombre, como en `title_of()`). Si el archivo no lo dice por fuera —un
  XCI nunca lo dice, y hay NSP convertidos desde cartucho que no traen
  ticket— la app descifra la cabecera de su NCA de metadatos con la
  `header_key` del `prod.keys` configurado: 0x400 bytes por archivo, nunca el
  contenido (AES-XTS-128 propio, `Sources/NXCore/NCAHeader.swift`). Si aun así
  no sale —no hay claves configuradas o no valen para ese archivo— la app
  sugiere uno por nombre desde la tabla de compatibilidad y el jugador lo
  confirma. De un XCI se lee además sin claves cuántos contenidos trae su
  partición `secure`: más de uno es un «1G+1U», y nxnative solo usa la base.

- **Ajustes de juego**: se dibujan desde `Contents/Resources/dm/launcher.json`
  y se guardan en `~/Library/Application Support/NXNativeMac/configuration.sqlite`.
  Cada perfil se materializa además en `~/Library/Application Support/nxnative/<title ID>/env.txt`,
  que el lanzador de nxnative lee, por lo que vale también al abrir el juego
  desde Finder. Como la app del iPhone, solo se escribe lo que difiere del
  valor probado, para que un build nuevo pueda mejorar los valores por
  defecto. Las líneas escritas a mano se conservan; si `env.txt` cambia fuera
  de la app, esa edición se importa en la siguiente carga. Si SQLite no está
  disponible, `env.txt` sigue siendo el respaldo operativo. La pestaña Ajustes
  también ofrece «Sincronizar ahora» y cada cambio comprueba antes si el
  archivo externo cambió mientras la vista estaba abierta.
- **HUD de Metal.** macOS mete `MTL_HUD_ENABLED=0` en el entorno de toda
  app que abre LaunchServices, y Metal lee esa variable al cargar su librería,
  antes que los constructores del host: el `setenv` del host (sin
  sobrescribir) nunca lo encendía, aunque el log dijera «HUD on». La app lo
  pasa en el entorno del arranque, y el lanzador de nxnative de este fork lo
  pone él mismo (sobrescribiendo), así que también sale al abrir el juego
  desde Finder en apps construidas después del cambio. Comprobado con capturas,
  por las dos vías de presentado (clásica y Metal 4).
- **Iconos de botones de PlayStation.** `make_ext_font.py --style playstation`
  dibuja, en los mismos puntos de código, el símbolo del botón de un mando de
  Sony en la misma posición (el host asigna por posición: A = ○, B = ✕,
  X = △, Y = □). La app la genera en
  `~/Library/Application Support/NXNativeMac/fonts/` y la activa por juego con
  `DM_SHARED_FONT_EXT`, sin reconstruir. Solo cambia los juegos que dibujan
  los botones con la fuente del sistema.
- **Arranque y salida con DualSense.** La biblioteca muestra una pantalla de
  entrada con el icono de NXNative mientras termina el primer escaneo, para
  evitar un salto brusco a las carátulas. Mientras un juego está abierto,
  mantener `Select + Start` (los botones `Options` + `Menu` que expone macOS)
  o el click del panel táctil de un DualSense durante el tiempo configurado en
  **Entorno → Salida global con mando** (5 segundos por defecto) envía
  `SIGTERM` al lanzador y devuelve el foco a `Juegos`; las acciones normales
  del mando no se roban al juego.
- **El parser de `env.txt` replica `env_file()` de `dm/mac/launcher.c`**: gana
  la primera aparición, `#` comenta, la clave pierde los espacios finales.
- **Los juegos se abren por LaunchServices**, no como hijos de esta app: el
  lanzador tiene que ser el proceso responsable para que TCC le deje leer un
  disco externo (ver «Why the host is a child process» en
  `docs/development.md`). Detener envía SIGTERM al lanzador, que lo reenvía.
- **El log se colorea, no se interpreta.** nxnative avisa de que sus líneas son
  diagnóstico para personas y no una interfaz.
- **Partidas.** Viven en `~/Library/Application Support/nxnative/<title ID>/save`,
  fuera de la app: reinstalar o reconstruir el juego no las toca. Lo que sí
  las borra es un desinstalador que limpie Application Support, borrar la
  carpeta o cambiar de Mac sin migrarla. Por eso:
  - **Copia automática** antes de jugar desde la app y antes de reconstruir un
    juego instalado, solo si la partida cambió desde la última (se compara
    una huella de rutas, tamaños y fechas, sin leer el contenido). Se guardan
    las 10 más nuevas; las manuales no se borran nunca.
  - **Exportar / Importar**: un zip con `save/` y `nxnative-save.json`
    (title ID, juego, versión, huella) que puedes guardar donde quieras.
    Importar la partida de otro juego se rechaza.
  - **La carpeta de copias se cambia en Entorno**: en iCloud Drive o en otro
    disco sobrevive a lo que borre Application Support.
  - **Restaurar o importar** copia antes la partida actual y manda la carpeta
    vieja a la Papelera: dos caminos de vuelta.
  - **Borrar partida** hace lo mismo: una copia «antes de borrar» y la carpeta
    a la Papelera. La partida del «dispositivo» (`save_device`) no se toca.
  - **Todas a la vez** (menú Partidas de la Biblioteca): un zip con una
    carpeta por juego y un índice `nxnative-saves.json`. Al importarlo, cada
    juego pasa por lo mismo que restaurar uno; uno que aún no está instalado
    recibe su partida igual, en la carpeta de su title ID.
- **Perfiles.** Para que varias personas compartan el Mac con partidas
  propias. «Principal» usa la carpeta de siempre, la que ve el juego abierto
  desde Finder. Los demás guardan en
  `…/nxnative/<title ID>/perfiles/<id>/save`: la app se lo pasa al juego con
  `DM_SAVE`, que el lanzador respeta si ya viene puesto, así que **solo
  valen al jugar desde la app**. Las copias también van por perfil
  (`<copias>/perfiles/<id>`), y los ajustes del juego son comunes.
  - El build de desarrollo (`--platform mac`) guarda en otro sitio,
    `<title ID>_build/run/save`, y no es la misma partida que la de la app.

## Compilar

### Instalador de FC26/FC27

La pantalla **Instalar FC26/FC27** no necesita que el juego esté previamente
indexado en la biblioteca. Selecciona una carpeta que contenga tu copia base,
actualización y DLC, selecciona tu propio `prod.keys` y pulsa **Generar**. El
title ID identifica automáticamente el juego: FC27 usa
`scripts/build_ipa_from_nsp.py --platform mac-app` y su launcher específico;
FC26 se envía a su builder dedicado. Al compilar `NXNativeMac.app`,
`build_app.sh` copia esa toolchain a `Contents/Resources/nxnative` y el
builder de FC26 a `Contents/Resources/fc26-mac-port`. Se excluyen `.git`,
`work`, resultados anteriores, dumps y claves. Por eso el `.app` se puede
mover a otro Mac compatible sin conservar el checkout de desarrollo; solo se
aportan el juego y las claves propias en cada instalación.

Necesita Xcode/Metal Toolchain, las herramientas nativas de macOS, Python
3.12 o posterior, .NET 10, `zstd` y `glslang` en un Mac con Apple silicon.
Para FC26 también hacen falta las librerías Homebrew `opus` y `libvpx`. La
pantalla **Entorno** comprueba estas dependencias y el instalador de FC26/FC27
no inicia el build mientras falte alguna. La app prepara su entorno Python de
usuario; no instala ni incluye la copia del juego ni las claves.
Las apps de FC26 y FC27 se firman ad hoc por defecto. Si en **Entorno** se
elige una identidad válida del llavero, la misma identidad se pasa a ambos
builders; así se puede usar Developer ID sin cambiar el flujo de instalación.

```bash
frontend/NXNativeMac/scripts/build_app.sh
```

Compila, monta `frontend/NXNativeMac/build/NXNativeMac.app` con su icono
(dibujado por `scripts/make_icon.swift`, con formas propias: ni SF Symbols ni
marcas de terceros), la firma ad hoc y la copia a `/Applications` (o a
`~/Applications` si no hay permiso). `--no-install` se salta la copia; con una
identidad de firma: `scripts/build_app.sh "Developer ID Application: …"`.

Durante el desarrollo:

```bash
swift test --package-path frontend/NXNativeMac
```

## Console navigation

The main window opens on the game library, without a sidebar. Select a cover
and play; game configuration opens separately inside the same window, preserving
the selected game when returning.

| Action | Keyboard / mouse | PlayStation | Switch | Xbox |
| --- | --- | --- | --- | --- |
| Select game | Left / Right, click a cover | D-pad / left stick | D-pad / left stick | D-pad / left stick |
| Play / resume | Enter, Play, double-click a cover | Cross | A | A |
| Open configuration | C, Command-comma, Configuration, cover context menu | Triangle | X | Y |
| Return to games | Esc, Back | Circle | B | B |
| Configuration sections | Click a tab, Command-[ / Command-] | L1 / R1 | L / R | LB / RB |
| Select / adjust a setting | Up / Down, Left / Right, visible row buttons | D-pad | D-pad | D-pad |

Native controls also support Tab and Space. The Advanced page includes a text
editor for arbitrary values. Global settings and builder/maintenance tools are
available from the configuration tabs. Controller glyphs are read from
GameController so the legends reflect system remapping; family labels are only
fallbacks. The top face button always opens configuration. Nintendo confirmation
uses the right face button, following the A/B convention of that console.

Back never terminates a game. The separately configured global exit gesture
(Select + Start or DualSense touchpad click, held for five seconds by default)
continues to return to the library. A short press does not trigger this exit.

Validation: run `swift test --jobs 2` and build with `SWIFT_BUILD_JOBS=2`.
Controller routing tests cover library/configuration boundaries, empty libraries,
explicit exit, and the three controller families. Physical-controller behavior
and visible keyboard/mouse interaction require testing the installed app.

## Workshop

Configuration → **Taller** opens the build workspace inside the console window.
The game settings also have **Reconstruir en el Taller**, preserving the selected
game. **Preparar** chooses source, Mac app or unsigned IPA, output directory and
one, two, four or six workers. **Actividad** contains progress, messages, cancellation and
explicit retry. **Herramientas** adds source folders and keys, rescans, and opens
the existing advanced installer/profile/save workflows.

The D-pad or left stick moves between rows; left/right changes a row's value;
the confirmation button activates it. Triangle / Switch X / Xbox Y cycles the
three Workshop views. The keyboard uses arrows, Enter, T and Esc. Mouse users
can activate rows, adjustment buttons and tabs directly. macOS file selectors
and the legacy advanced forms retain their native keyboard/mouse interaction.
Build, retry and cancellation confirmations start on Back and are operable with
controller or keyboard. Opening the Workshop never starts a build.

Builds remain sequential. The default is one worker, with optional two-, four-
and six-worker modes, explicit compiler environment limits and background
scheduling priority. Four and six workers can shorten shader and compiler stages
on machines with enough CPU and memory, but use more RAM and do not accelerate
serial stages.
These are concurrency limits, not a hard cap on a compiler's memory allocation.
macOS memory-pressure warnings hold the next job; critical pressure requests
cancellation of the active job. Source and key paths are checked again when a
queued job starts, and the save backup is awaited before rebuilding an installed
game. A successfully completed build triggers a library refresh.

Build metadata and up to 100 finished jobs are saved in the existing SQLite
database, without key contents. Jobs interrupted by a previous app session are
shown for manual review and are never restarted automatically. Retry is refused
while a recorded previous process ID still exists; that PID is never terminated
based on the stored number alone. Detailed build logs stay with the source game.

Closing the last window keeps NXNative running while jobs are pending. Quitting
the app explicitly requires cancelling those jobs and waits for their exit.
This is an in-app queue with child build processes, not a detached system service.
An app crash or restart therefore requires reviewing interrupted jobs.

Validation uses `swift test --jobs 2`. The process-queue tests launch only tiny
local commands, covering failure progression, cancellation before launch and
history recovery; they do not compile game shaders or establish game playability.

## Estructura

```
Sources/NXCore/        Formatos de nxnative, sin UI (se prueba solo)
  BuildEvent.swift       eventos de --progress json
  BuildState.swift       reductor de etapas y mensajes
  EnvFile.swift          env.txt, con las reglas del lanzador
  ConfigurationDatabase.swift SQLite + materialización compatible de env.txt
  LauncherSettings.swift dm/launcher.json
  TitleID.swift          title IDs y carpetas NSP
  NCAHeader.swift        title ID con claves (AES-XTS-128 propio)
  MacGameBundle.swift    apps de juego empaquetadas y sus rutas
  Repository.swift       el checkout: perfiles, tabla de juegos, chain lock, interruptores
  BuildOptions.swift     opciones → argumentos del script
  Shell.swift            procesos cortos
Sources/NXNativeMac/   La app (SwiftUI)
Tests/NXCoreTests/     Pruebas; Fixtures/progress.jsonl lo emitió la clase
                       Progress REAL del script, no una imitación
```

## Qué falta

- No se ha probado todavía con un build real de un juego: el flujo de
  eventos está verificado contra el emisor real de nxnative, pero no un build
  de principio a fin.
- Mientras el juego corre, nxnative solo informa por el log. Cuando publique
  eventos legibles por programa (lo menciona como siguiente pieza), la vista
  de log debería usarlos para mandos, preparación de shaders y errores.
- Instalar la IPA en el iPhone queda fuera: es sideloading y lo hace el
  jugador.
- Existe un front end de la comunidad,
  [NX2Apple](https://github.com/LNPANDY/NX2Apple), centrado en el iPhone; este
  se centra en el Mac (biblioteca, ajustes, partidas, benchmark).
