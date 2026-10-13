import CoreGraphics

/// Samples backgrounds from the existing capture; no additional screenshots are taken.
enum CapturedAppearance {
    static func fallback(image:CGImage,logicalBounds:CGRect,area:CGRect? = nil) -> OverlayStyle {
        if let area { return analyze(image:image,pane:area,cursorY:area.midY) }
        guard logicalBounds.width.isFinite,logicalBounds.height.isFinite,logicalBounds.width > 0,logicalBounds.height > 0 else { return .fallback }
        let w = min(0.95,OverlayGeometry.compactMinimumWidth/logicalBounds.width),h = min(0.5,42/logicalBounds.height)
        let pane = CGRect(x:min(0.02,16/logicalBounds.width),y:1-h,width:w,height:h)
        return analyze(image:image,pane:pane,cursorY:1-h/2)
    }
    static func analyze(image: CGImage,pane: CGRect,cursorY: CGFloat) -> OverlayStyle {
        guard !Task.isCancelled, cursorY.isFinite, image.width <= 16384, image.height <= 16384,
              image.width <= 64_000_000 / max(1,image.height),
              [pane.minX,pane.minY,pane.width,pane.height].allSatisfy(\.isFinite),
              pane.width > 0, pane.height > 0 else { return .fallback }
        let bounds = CGRect(x:0,y:0,width:image.width,height:image.height)
        let area = CGRect(x:pane.minX*bounds.width,y:pane.minY*bounds.height,
                          width:pane.width*bounds.width,height:pane.height*bounds.height).intersection(bounds)
        guard !area.isNull,area.width > 8,area.height > 8 else { return .fallback }
        let height = min(area.height,max(24,bounds.height*0.08))
        let cursor = min(area.maxY,max(area.minY,cursorY*bounds.height))
        let band = CGRect(x:area.minX+area.width*0.04,y:min(area.maxY-height,max(area.minY,cursor-height/2)),
                          width:area.width*0.92,height:height).integral.intersection(area)
        guard let sample = image.cropping(to:band), let space = CGColorSpace(name:CGColorSpace.sRGB),
              let context = CGContext(data:nil,width:128,height:32,bitsPerComponent:8,bytesPerRow:128*4,
                space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to:UInt8.self) else { return .fallback }
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:128,height:32))
        context.interpolationQuality = .none;context.draw(sample,in:CGRect(x:0,y:0,width:128,height:32))
        guard !Task.isCancelled else { return .fallback }
        // Group similar colors, then average only the dominant group so text
        // and antialiased edges do not tint a solid background.
        var counts = [Int](repeating:0,count:4096)
        var red = counts, green = counts, blue = counts
        for i in stride(from:0,to:128*32*4,by:4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            let bin = (r>>4)*256 + (g>>4)*16 + (b>>4)
            counts[bin] += 1; red[bin] += r; green[bin] += g; blue[bin] += b
        }
        let bin = counts.indices.max { counts[$0] < counts[$1] }!
        let count = counts[bin]
        let r = UInt8(red[bin]/count), g = UInt8(green[bin]/count), b = UInt8(blue[bin]/count)
        if r == 0 && g == 0 && b == 0 { return .dark }
        if r == 255 && g == 255 && b == 255 { return .light }
        return .sampled(red:r,green:g,blue:b)
    }
}
