// Dibuja el icono de NXNativeMac (1024x1024 PNG) solo con formas propias:
// nada de SF Symbols (su licencia no permite usarlos en iconos de apps) ni
// de marcas de terceros. Un mando blanco sobre el fondo con la forma y los
// márgenes de los iconos de macOS (contenido de 824 px, radio 185).
//
// Uso: swift make_icon.swift salida.png
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Fondo: la placa redondeada de macOS, con degradado índigo → violeta y una
// sombra suave debajo.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(platePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.36, green: 0.22, blue: 0.86, alpha: 1).cgColor,
                             NSColor(red: 0.10, green: 0.12, blue: 0.36, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Brillo arriba, como el vidrio de los iconos del sistema.
let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// El mando: cuerpo con dos asas, y los controles recortados (relleno par-impar).
let body = CGMutablePath()
body.addRoundedRect(in: CGRect(x: 232, y: 400, width: 560, height: 250), cornerWidth: 125, cornerHeight: 125)
body.addEllipse(in: CGRect(x: 214, y: 300, width: 230, height: 300))   // asa izquierda
body.addEllipse(in: CGRect(x: 580, y: 300, width: 230, height: 300))   // asa derecha
let holes = CGMutablePath()
// Cruceta.
holes.addRoundedRect(in: CGRect(x: 300, y: 497, width: 130, height: 46), cornerWidth: 12, cornerHeight: 12)
holes.addRoundedRect(in: CGRect(x: 342, y: 455, width: 46, height: 130), cornerWidth: 12, cornerHeight: 12)
// Cuatro botones en rombo.
for (dx, dy) in [(0.0, 52.0), (52.0, 0.0), (0.0, -52.0), (-52.0, 0.0)] {
    holes.addEllipse(in: CGRect(x: 680 + dx - 25, y: 520 + dy - 25, width: 50, height: 50))
}
// Dos sticks.
holes.addEllipse(in: CGRect(x: 424, y: 424, width: 64, height: 64))
holes.addEllipse(in: CGRect(x: 536, y: 424, width: 64, height: 64))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
// El cuerpo es la unión de tres formas: se rellena con «no cero» para que los
// solapes no se anulen, y los agujeros se pintan después del color del fondo
// por encima (con mezcla de copia, para que se vea el degradado: se recorta).
ctx.addPath(body); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath(using: .winding)
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
ctx.addPath(holes); ctx.clip()
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print(out.path)
