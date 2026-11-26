// 產生 App 圖示：swift Tools/make_icon.swift <輸出資料夾.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// 以 1024 × 1024 座標繪製：深藍到青綠底、白色麥克風、左右對稱聲波
func draw(_ g: CGContext) {
    let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
    g.addPath(plate)
    g.setFillColor(color(0x1E1B4B))
    g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(plate)
    g.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x312E81), color(0x2563EB), color(0x14B8A6)] as CFArray,
                              locations: [0, 0.55, 1])!
    g.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    g.restoreGState()

    g.setLineCap(.round)
    // 聲波
    for (radius, alpha) in [(CGFloat(224), CGFloat(0.85)), (CGFloat(306), CGFloat(0.45))] {
        g.setStrokeColor(color(0xFFFFFF, alpha))
        g.setLineWidth(34)
        for center in [CGFloat(0), CGFloat.pi] {
            g.addArc(center: CGPoint(x: 512, y: 578), radius: radius,
                     startAngle: center - 0.62, endAngle: center + 0.62, clockwise: false)
            g.strokePath()
        }
    }
    // 麥克風本體
    g.setFillColor(color(0xFFFFFF))
    g.addPath(CGPath(roundedRect: CGRect(x: 412, y: 452, width: 200, height: 330),
                     cornerWidth: 100, cornerHeight: 100, transform: nil))
    g.fillPath()
    // 支架
    g.setStrokeColor(color(0xFFFFFF))
    g.setLineWidth(40)
    g.addArc(center: CGPoint(x: 512, y: 540), radius: 160, startAngle: .pi, endAngle: 0, clockwise: false)
    g.strokePath()
    g.move(to: CGPoint(x: 512, y: 380))
    g.addLine(to: CGPoint(x: 512, y: 268))
    g.move(to: CGPoint(x: 414, y: 258))
    g.addLine(to: CGPoint(x: 610, y: 258))
    g.strokePath()
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let g = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        g.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        draw(g)
        let rep = NSBitmapImageRep(cgImage: g.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
