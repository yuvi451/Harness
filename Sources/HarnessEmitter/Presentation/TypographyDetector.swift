import CoreGraphics
import CoreText
import Foundation
import Vision
import CoreML

/// Bounded, local OCR plus raster comparison against installed fonts. Pixel estimates
/// cannot recover a missing font, CSS metadata, variable-font axes or an exact font identity.
enum TypographyDetector {
    private static let candidates:[String] = {
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []).sorted()
        let preferred = ["Satoshi", "Menlo", "Monaco", "Arial", "Helvetica", "TimesNewRoman", "Georgia", "Courier", "Verdana", "Inter", "Roboto", "OpenSans", "SFPro"]
        let first = names.filter { n in preferred.contains { n.hasPrefix($0) } }
        return Array((first + names.filter { !first.contains($0) && !$0.localizedCaseInsensitiveContains("emoji") && !$0.localizedCaseInsensitiveContains("symbol") }).prefix(128))
    }()

    static func analyze(image:CGImage,pane:CGRect,logicalWidth:CGFloat) -> AdaptiveTypography? {
        guard !Task.isCancelled,logicalWidth.isFinite,logicalWidth > 0,image.width >= 100,image.height >= 30,
              image.width <= 16384,image.height <= 16384,image.width <= 64_000_000 / image.height,
              [pane.minX,pane.minY,pane.width,pane.height].allSatisfy(\.isFinite) else { return nil }
        let area = pane.intersection(CGRect(x:0,y:0,width:1,height:1))
        guard !area.isNull,area.width > 0,area.height > 0 else { return nil }
        // Analyze a bounded-resolution copy; preserve logical units on Retina displays.
        let factor = min(1,2048.0/Double(image.width),1280.0/Double(image.height))
        let width = max(1,Int(Double(image.width)*factor)),height = max(1,Int(Double(image.height)*factor))
        guard let context = context(width:width,height:height) else { return nil }
        context.interpolationQuality = .high; context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        guard let bounded = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        // CPU OCR avoids unsupported accelerator/compiler paths on older hardware.
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu,for:.main)
        }
        request.recognitionLevel = .fast; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.008
        request.regionOfInterest = CGRect(x:area.minX,y:1-area.maxY,width:area.width,height:area.height)
        let deadline = DispatchWorkItem { request.cancel() }
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+3,execute:deadline)
        defer { deadline.cancel() }
        do { try VNImageRequestHandler(cgImage:bounded,options:[:]).perform([request]) }
        catch { return nil }
        guard !Task.isCancelled else { return nil }
        var estimates:[AdaptiveTypography] = []
        // OCR and font comparison each have a bounded work budget. Keep earlier
        // complete matches when later samples run out of time.
        let matchingDeadline = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
        let eligible = Array((request.results ?? []).prefix(300)).filter {
            guard let text = $0.topCandidates(1).first else { return false }
            return text.confidence >= 0.45 && (8...2048).contains(text.string.count)
        }.sorted { $0.boundingBox.height < $1.boundingBox.height }
        // Vote across the complete set before taking samples. Sampling the
        // largest three lines alone selects headings instead of repeated body text.
        var groups:[[VNRecognizedTextObservation]] = []
        for line in eligible {
            if let first = groups.last?.first,line.boundingBox.height <= first.boundingBox.height*1.15 {
                groups[groups.count-1].append(line)
            } else { groups.append([line]) }
        }
        let dominant = groups.sorted {
            $0.count == $1.count ? $0[0].boundingBox.height < $1[0].boundingBox.height : $0.count > $1.count
        }.first ?? []
        let lines = dominant.sorted { ($0.topCandidates(1).first?.confidence ?? 0) > ($1.topCandidates(1).first?.confidence ?? 0) }.prefix(3)
        for line in lines {
            if DispatchTime.now().uptimeNanoseconds >= matchingDeadline { break }
            guard !Task.isCancelled,let text = line.topCandidates(1).first else { return nil }
            var box = line.boundingBox
            var sample = text.string
            if sample.count > 90 {
                let cutoff = sample.index(sample.startIndex,offsetBy:90)
                let prefix = sample[..<cutoff]
                let boundary = prefix.lastIndex(where: { $0.isWhitespace }) ?? cutoff
                guard sample.distance(from:sample.startIndex,to:boundary) >= 8,
                      let bounds = try? text.boundingBox(for:sample.startIndex..<boundary) else { continue }
                box = bounds.boundingBox;sample = String(sample[..<boundary])
            }
            let pixels = CGRect(x:box.minX*CGFloat(width),y:(1-box.maxY)*CGFloat(height),
                                width:box.width*CGFloat(width),height:box.height*CGFloat(height)).insetBy(dx:-2,dy:-2)
                .integral.intersection(CGRect(x:0,y:0,width:width,height:height))
            guard let crop = bounded.cropping(to:pixels),
                  let estimate = match(text:sample,image:crop,logicalScale:Double(logicalWidth)/Double(width),candidates:candidates,
                                       deadline:matchingDeadline) else { continue }
            estimates.append(estimate)
        }
        let fonts = Dictionary(grouping:estimates,by:\.fontName).values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return ($0.map(\.confidence).max() ?? 0) > ($1.map(\.confidence).max() ?? 0)
        }
        guard let consistent = fonts.first,let first = consistent.first else { return nil }
        let sizes = consistent.map(\.pointSize).sorted()
        return AdaptiveTypography(fontName:first.fontName,pointSize:sizes[sizes.count/2],
                                  confidence:consistent.map(\.confidence).reduce(0,+)/Double(consistent.count))
    }

    static func renderSample(text:String,font:CTFont) -> CGImage? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[
            NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]))
        let bounds = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width > 0,bounds.height > 0,
              bounds.width < 8192,bounds.height < 512,
              let canvas = context(width:Int(ceil(bounds.width))+4,height:Int(ceil(bounds.height))+4) else { return nil }
        canvas.setFillColor(CGColor(gray:1,alpha:1));canvas.fill(CGRect(x:0,y:0,width:canvas.width,height:canvas.height))
        canvas.textPosition = CGPoint(x:2-bounds.minX,y:2-bounds.minY)
        CTLineDraw(line,canvas)
        return canvas.makeImage()
    }

    static func match(text:String,image:CGImage,logicalScale:Double,candidates:[String],deadline:UInt64? = nil) -> AdaptiveTypography? {
        guard !Task.isCancelled,deadline.map({ DispatchTime.now().uptimeNanoseconds < $0 }) ?? true,
              (8...90).contains(text.count),logicalScale.isFinite,(0.125...8).contains(logicalScale),
              let source = mask(image) else { return nil }
        var ranked:[(score:Double,name:String,size:Double)] = []
        for name in candidates.prefix(128) {
            if Task.isCancelled || deadline.map({ DispatchTime.now().uptimeNanoseconds >= $0 }) == true { return nil }
            let base = CTFontCreateWithName(name as CFString,100,nil)
            guard CTFontCopyPostScriptName(base) as String == name else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):base]))
            let ink = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
            guard ink.height > 0,ink.width > 0 else { continue }
            // A whole text line gives a much less quantized size estimate than
            // the handful of vertical pixels in small body text.
            let estimatedSize = Double(source.width)/Double(ink.width)*100
            let size = (estimatedSize*4).rounded()/4
            let logicalSize = size*logicalScale
            guard (8...28).contains(logicalSize),
                  let raster = renderSample(text:text,font:CTFontCreateWithName(name as CFString,size,nil)),
                  let template = mask(raster) else { continue }
            let aspect = abs(log(Double(template.width)/Double(template.height) / (Double(source.width)/Double(source.height))))
            guard aspect < 0.24 else { continue }
            var difference:Double = 0,union:Double = 0
            for (a,b) in zip(source.values,template.values) { difference += Double(abs(a-b));union += Double(max(a,b)) }
            let score = difference/max(1,union) + aspect*1.5
            ranked.append((score,name,logicalSize))
        }
        ranked.sort { $0.score < $1.score }
        guard let best = ranked.first,best.score <= 0.38 else { return nil }
        // Near-identical installed aliases cannot be distinguished from pixels.
        if ranked.count > 1,ranked[1].score-best.score < 0.012 { return nil }
        return AdaptiveTypography(fontName:best.name,pointSize:best.size,confidence:1-best.score)
    }

    private static func context(width:Int,height:Int) -> CGContext? {
        guard width > 0,height > 0,width <= 16384,height <= 16384,width <= 64_000_000/height,
              let space = CGColorSpace(name:CGColorSpace.sRGB) else { return nil }
        return CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }
    private struct InkMask { let width:Int,height:Int; let values:[Float] }
    private static func mask(_ image:CGImage) -> InkMask? {
        guard image.width <= 8192,image.height <= 512,
              let canvas = context(width:image.width,height:image.height),let bytes = canvas.data?.assumingMemoryBound(to:UInt8.self) else { return nil }
        canvas.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        var bins = [Int:Int]()
        for i in stride(from:0,to:image.width*image.height*4,by:4) {
            let bin = Int(bytes[i]>>4)*256 + Int(bytes[i+1]>>4)*16 + Int(bytes[i+2]>>4)
            bins[bin,default:0] += 1
        }
        guard let background = bins.max(by: { $0.value < $1.value })?.key else { return nil }
        var red = 0,green = 0,blue = 0,count = 0
        for i in stride(from:0,to:image.width*image.height*4,by:4) {
            let bin = Int(bytes[i]>>4)*256 + Int(bytes[i+1]>>4)*16 + Int(bytes[i+2]>>4)
            if bin == background { red += Int(bytes[i]);green += Int(bytes[i+1]);blue += Int(bytes[i+2]);count += 1 }
        }
        guard count > 0 else { return nil }
        let color = [red/count,green/count,blue/count]
        var ink = [Float](repeating:0,count:image.width*image.height)
        var contrastCounts = [Int](repeating:0,count:256)
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y*image.width+x)*4
            let contrast = max(abs(Int(bytes[i])-color[0]),max(abs(Int(bytes[i+1])-color[1]),abs(Int(bytes[i+2])-color[2])))
            ink[y*image.width+x] = Float(contrast)
            if contrast >= 8 { contrastCounts[contrast] += 1 }
        } }
        let target = max(1,Int(Double(contrastCounts.reduce(0,+))*0.95))
        var total = 0,peak = 8
        for value in 8...255 {
            total += contrastCounts[value]
            if total >= target { peak = value;break }
        }
        guard peak >= 24 else { return nil }
        let threshold = max(8,Float(peak)*0.12)
        var x0 = image.width,y0 = image.height,x1 = -1,y1 = -1
        for y in 0..<image.height { for x in 0..<image.width {
            let index = y*image.width+x
            if ink[index] >= threshold {
                ink[index] = min(1,ink[index]/Float(peak))
                x0 = min(x0,x);x1 = max(x1,x);y0 = min(y0,y);y1 = max(y1,y)
            } else { ink[index] = 0 }
        } }
        guard x1 > x0,y1 > y0 else { return nil }
        let width = x1-x0+1,height = y1-y0+1
        var scaled = [Float](repeating:0,count:160*32)
        for y in 0..<32 { for x in 0..<160 {
            let px = Double(x)*Double(width-1)/159,py = Double(y)*Double(height-1)/31
            let ix = Int(px),iy = Int(py),nx = min(width-1,ix+1),ny = min(height-1,iy+1)
            let fx = Float(px-Double(ix)),fy = Float(py-Double(iy))
            let a = ink[(y0+iy)*image.width+x0+ix]*(1-fx)+ink[(y0+iy)*image.width+x0+nx]*fx
            let b = ink[(y0+ny)*image.width+x0+ix]*(1-fx)+ink[(y0+ny)*image.width+x0+nx]*fx
            scaled[y*160+x] = a*(1-fy)+b*fy
        } }
        return InkMask(width:width,height:height,values:scaled)
    }
}
