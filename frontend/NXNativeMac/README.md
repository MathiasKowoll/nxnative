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
| **Biblioteca** | Las apps de juego empaquetadas (`DMTitleID` en su `Info.plist`). Jugar / detener, ajustes por juego, log en vivo, copias de las partidas guardadas, interruptores avanzados. |
| **Juegos en disco** | Base, actualizaciones y DLC agrupados por title ID, estén en una carpeta por juego o todos juntos con los DLC en subcarpetas. Dice si nxnative tiene perfil y avisa de un XCI que trae la actualización en el cartucho. Construye una app de Mac, una IPA o un build de desarrollo, con todas las opciones del script. Benchmark (`scripts/bench.py`) cuando el perfil tiene ruta. |
| **Construcciones** | Cola de builds de uno en uno, con etapas, progreso, ETA y la consola del script. Cancelar manda SIGINT (el script sale con 130 y deja lo reutilizable). |
| **Compatibilidad** | La tabla de `dm/games/README.md` cruzada con lo que tienes. Cada juego enlaza a su nota en el checkout. |
| **Entorno** | Comprobaciones reales: Apple silicon, Metal 4 y arquitectura de la GPU, Python ≥ 3.12, `nsz`, Xcode, versión del compilador de Metal contra `dmsh_chain.lock`, permisos de `prod.keys`, espacio libre. Clonar o actualizar nxnative (`git pull --ff-only`). Mandos que ve macOS. |

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
  y se escriben en `~/Library/Application Support/nxnative/<title ID>/env.txt`,
  que el lanzador de nxnative lee. Valen también al abrir el juego desde
  Finder. Como la app del iPhone, solo se escribe lo que difiere del valor
  probado, para que un build nuevo pueda mejorar los valores por defecto. Las
  líneas escritas a mano en ese archivo se conservan.
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
  - El build de desarrollo (`--platform mac`) guarda en otro sitio,
    `<title ID>_build/run/save`, y no es la misma partida que la de la app.

## Compilar

Necesita Xcode (Swift 6) en un Mac con Apple silicon.

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

## Estructura

```
Sources/NXCore/        Formatos de nxnative, sin UI (se prueba solo)
  BuildEvent.swift       eventos de --progress json
  BuildState.swift       reductor de etapas y mensajes
  EnvFile.swift          env.txt, con las reglas del lanzador
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
