# NXNative para Mac

Aplicación de administración en SwiftUI para
[nxnative](https://github.com/MathiasKowoll/nxnative): construye tus juegos de
Switch como apps nativas de Mac (o IPA), los guarda en una biblioteca, ajusta
cada juego, los arranca y sigue su log.

Vive en `frontend/NXNativeMac` del fork, pero no toca nada de nxnative: usa
la interfaz que nxnative documenta para front ends (`docs/frontends.md`). Si
nxnative cambia esa interfaz, el punto de contacto está en `Sources/NXCore`.

> Juegos y claves son tuyos. La app no incluye ni descarga nada de ningún
> juego, y de `prod.keys` solo guarda la **ruta**: nunca abre el archivo, se lo
> pasa al script con `-k`.

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
- **Title ID sin claves.** De un NSP/NSZ se lee el ticket de su PFS0 (gana a
  la etiqueta del nombre, como en `title_of()`). Un XCI lo guarda en NCAs
  cifrados, así que sin claves solo se sabe por el nombre; si no lo lleva, la
  app sugiere uno por nombre desde la tabla de compatibilidad y el jugador lo
  confirma. De un XCI sí se lee sin claves cuántos contenidos trae su
  partición `secure`: más de uno es un «1G+1U», y nxnative solo usa la base.

- **Ajustes de juego**: se dibujan desde `Contents/Resources/dm/launcher.json`
  y se escriben en `~/Library/Application Support/nxnative/<title ID>/env.txt`,
  que el lanzador de nxnative lee. Valen también al abrir el juego desde
  Finder. Como la app del iPhone, solo se escribe lo que difiere del valor
  probado, para que un build nuevo pueda mejorar los valores por defecto. Las
  líneas escritas a mano en ese archivo se conservan.
- **El parser de `env.txt` replica `env_file()` de `dm/mac/launcher.c`**: gana
  la primera aparición, `#` comenta, la clave pierde los espacios finales.
- **Los juegos se abren por LaunchServices**, no como hijos de esta app: el
  lanzador tiene que ser el proceso responsable para que TCC le deje leer un
  disco externo (ver «Why the host is a child process» en
  `docs/development.md`). Detener envía SIGTERM al lanzador, que lo reenvía.
- **El log se colorea, no se interpreta.** nxnative avisa de que sus líneas son
  diagnóstico para personas y no una interfaz.
- **Restaurar una partida** hace antes una copia de la actual y manda la
  carpeta vieja a la Papelera: es la única operación que podría perder datos.

## Compilar

Necesita Xcode (Swift 6) en un Mac con Apple silicon.

```bash
frontend/NXNativeMac/scripts/build_app.sh
```

Deja `frontend/NXNativeMac/build/NXNativeMac.app`, firmada ad hoc. Con una identidad de firma:
`scripts/build_app.sh "Developer ID Application: …"`.

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
