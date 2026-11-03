#import "QPDFBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pl_Buffer.hh>
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <set>
#include <map>
#include <array>

namespace {
using Object = QPDFObjectHandle;
using Token = QPDFTokenizer::Token;
// Keep source color-space identity separate from the emitted display color.
// A mapped gray switches the output to DeviceGray; the next SC/SCN still takes
// its operands in the source space (including spot, indexed and ICC spaces).
struct DrawingColorSpace {
    std::string selection = "/DeviceGray";
    Object definition = Object::newName("/DeviceGray");
    std::vector<double> initial = {0};
};

class DisplayColorConverter {
    QPDF& source;
    std::map<std::string, std::array<double, 3>> cache;
  public:
    explicit DisplayColorConverter(QPDF& source) : source(source) {}
    std::array<double, 3> rgb(DrawingColorSpace space, std::vector<double> const& values) {
        auto definition = space.definition;
        auto name = definition.isName() ? definition.getName() : "";
        auto unit = [](double value) { return std::clamp(value, 0.0, 1.0); };
        if (name == "/DeviceGray" && values.size() == 1) return {unit(values[0]), unit(values[0]), unit(values[0])};
        if (name == "/DeviceRGB" && values.size() == 3) return {unit(values[0]), unit(values[1]), unit(values[2])};
        if (name == "/DeviceCMYK" && values.size() == 4)
            return {(1-unit(values[0]))*(1-unit(values[3])), (1-unit(values[1]))*(1-unit(values[3])), (1-unit(values[2]))*(1-unit(values[3]))};
        std::ostringstream operands;
        operands << std::setprecision(17);
        for (double value : values) operands << value << " ";
        auto key = definition.unparse() + ":" + operands.str();
        if (auto found = cache.find(key); found != cache.end()) return found->second;
        if (cache.size() >= 4096) throw std::runtime_error("Display color conversion exceeds color budget");

        // Let the same macOS PDF engine that draws the source resolve its solid
        // colors. This covers sampled/exponential/stitching/calculator tint
        // functions, DeviceN, Indexed, Lab and embedded ICC profiles without
        // approximating a tint as gray or changing an image's color resources.
        QPDF probe;
        probe.emptyPDF();
        if (!definition.isIndirect()) definition = source.makeIndirectObject(definition);
        auto imported = probe.copyForeignObject(definition);
        auto spaces = Object::newDictionary(); spaces.replaceKey("/Sample", imported);
        auto resources = Object::newDictionary(); resources.replaceKey("/ColorSpace", spaces);
        auto page = Object::newDictionary();
        page.replaceKey("/Type", Object::newName("/Page"));
        page.replaceKey("/MediaBox", Object::parse("[0 0 2 2]"));
        page.replaceKey("/Resources", resources);
        page.replaceKey("/Contents", Object::newStream(&probe, "/Sample cs " + operands.str() + "scn 0 0 2 2 re f\n"));
        QPDFPageDocumentHelper(probe).addPage(QPDFPageObjectHelper(probe.makeIndirectObject(page)), false);
        QPDFWriter writer(probe); writer.setOutputMemory(); writer.write();
        auto data = writer.getBufferSharedPointer();
        auto provider = CGDataProviderCreateWithData(nullptr, data->getBuffer(), data->getSize(), nullptr);
        auto document = provider ? CGPDFDocumentCreateWithProvider(provider) : nullptr;
        if (provider) CGDataProviderRelease(provider);
        auto cgPage = document ? CGPDFDocumentGetPage(document, 1) : nullptr;
        uint8_t pixels[16] = {};
        auto colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        auto context = CGBitmapContextCreate(pixels, 2, 2, 8, 8, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(colorSpace);
        if (!cgPage || !context) {
            if (context) CGContextRelease(context);
            if (document) CGPDFDocumentRelease(document);
            throw std::runtime_error("Cannot resolve PDF display color");
        }
        CGContextSetGrayFillColor(context, 1, 1); CGContextFillRect(context, CGRectMake(0, 0, 2, 2));
        CGContextDrawPDFPage(context, cgPage);
        CGContextRelease(context); CGPDFDocumentRelease(document);
        std::array<double, 3> result = {pixels[0]/255.0, pixels[1]/255.0, pixels[2]/255.0};
        cache.emplace(key, result);
        return result;
    }
};
struct Matrix {
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;
    Matrix then(Matrix const& m) const {
        return {a*m.a+c*m.b, b*m.a+d*m.b, a*m.c+c*m.d, b*m.c+d*m.d,
                a*m.e+c*m.f+e, b*m.e+d*m.f+f};
    }
    static Matrix read(Object value) {
        if (value.isNull()) return {};
        if (!value.isArray() || value.getArrayNItems() != 6) throw std::runtime_error("Invalid form matrix");
        double v[6];
        for (int i = 0; i < 6; ++i) {
            auto item = value.getArrayItem(i);
            if (!item.isNumber() || !std::isfinite(item.getNumericValue())) throw std::runtime_error("Invalid form matrix");
            v[i] = item.getNumericValue();
        }
        return {v[0], v[1], v[2], v[3], v[4], v[5]};
    }
};
struct Rectangle {
    double x = 0, y = 0, width = 1, height = 1;
    static Rectangle read(Object value) {
        if (!value.isArray() || value.getArrayNItems() != 4) throw std::runtime_error("Missing form bounds");
        double v[4];
        for (int i = 0; i < 4; ++i) {
            auto item = value.getArrayItem(i);
            if (!item.isNumber() || !std::isfinite(item.getNumericValue())) throw std::runtime_error("Invalid form bounds");
            v[i] = item.getNumericValue();
        }
        return {std::min(v[0], v[2]), std::min(v[1], v[3]), std::abs(v[2]-v[0]), std::abs(v[3]-v[1])};
    }
    Rectangle transformed(Matrix const& m) const {
        double x0 = m.a*x + m.c*y + m.e, y0 = m.b*x + m.d*y + m.f;
        double xs[] = {x0, x0+m.a*width, x0+m.c*height, x0+m.a*width+m.c*height};
        double ys[] = {y0, y0+m.b*width, y0+m.d*height, y0+m.b*width+m.d*height};
        auto [xmin, xmax] = std::minmax_element(std::begin(xs), std::end(xs));
        auto [ymin, ymax] = std::minmax_element(std::begin(ys), std::end(ys));
        if (!std::isfinite(*xmin) || !std::isfinite(*xmax) || !std::isfinite(*ymin) || !std::isfinite(*ymax))
            throw std::runtime_error("Invalid transformed form bounds");
        return {*xmin, *ymin, *xmax-*xmin, *ymax-*ymin};
    }
};
struct DrawingState {
    DrawingColorSpace fill, stroke;
    std::string originalFill = "0 g\n", originalStroke = "0 G\n";
    double fillAlpha = 1, strokeAlpha = 1;
    Matrix transform;
};

// Lexical tokens keep strings, comments and binary inline images out of the
// operator parser. This filter is never attached to the original live PDF.
class DarkTokens final : public Object::TokenFilter {
    QPDF& pdf;
    DisplayColorConverter& converter;
    Object resources;
    DrawingState colors;
    Rectangle pageBounds;
    std::vector<DrawingState> stack;
    std::vector<Token> operands;
    std::string pending;
    std::string failure, opaqueBackdrop;
    bool inlineImage = false, inlineMaskKey = false, path = false;
    int depth;
    size_t& budget;
    std::set<QPDFObjGen> ancestors;
    DrawingColorSpace colorSpace(std::string name) {
        DrawingColorSpace result;
        result.selection = Object::newName(name).unparse();
        auto value = Object::newName(name);
        auto dictionary = resources.getKey("/ColorSpace");
        for (int depth = 0; value.isName() && depth < 8; ++depth) {
            auto kind = value.getName();
            if (kind == "/DeviceGray" || kind == "/DeviceRGB" || kind == "/DeviceCMYK") break;
            if (!dictionary.isDictionary() || !dictionary.hasKey(kind)) throw std::runtime_error("Missing drawing color space");
            value = dictionary.getKey(kind);
        }
        result.definition = value;
        int components = 0;
        bool subtractive = false;
        if (value.isName()) {
            name = value.getName();
            if (name == "/DeviceGray") components = 1;
            if (name == "/DeviceRGB") components = 3;
            if (name == "/DeviceCMYK") components = 4;
        } else if (value.isArray() && value.getArrayNItems() >= 2) {
            auto kind = value.getArrayItem(0);
            if (kind.isNameAndEquals("/CalGray")) components = 1;
            if (kind.isNameAndEquals("/CalRGB") || kind.isNameAndEquals("/Lab")) components = 3;
            if (kind.isNameAndEquals("/Indexed")) components = 1;
            if (kind.isNameAndEquals("/Separation") && value.getArrayNItems() == 4) { components = 1; subtractive = true; }
            if (kind.isNameAndEquals("/DeviceN") && value.getArrayNItems() >= 4) {
                auto names = value.getArrayItem(1);
                if (names.isArray()) components = names.getArrayNItems();
                subtractive = true;
            }
            if (kind.isNameAndEquals("/ICCBased")) {
                auto profile = value.getArrayItem(1);
                if (profile.isStream()) {
                    auto count = profile.getDict().getKey("/N");
                    if (count.isInteger()) {
                        if (count.getIntValue() == 1 || count.getIntValue() == 3 || count.getIntValue() == 4)
                            components = int(count.getIntValue());
                    }
                }
            }
        }
        if (components <= 0 || components > 32) throw std::runtime_error("Unsupported drawing color space: retain original page");
        result.initial.assign(components, subtractive ? 1 : 0);
        if (components == 4 && !subtractive) result.initial[3] = 1;
        return result;
    }
    std::string neutral(std::string const& op) {
        std::vector<double> values;
        for (auto const& t : operands) {
            if (t.getType() != QPDFTokenizer::tt_integer && t.getType() != QPDFTokenizer::tt_real) return "";
            double x = std::stod(t.getValue());
            if (!std::isfinite(x)) throw std::runtime_error("Invalid color component");
            values.push_back(x);
        }
        bool stroke = op == "G" || op == "RG" || op == "K" || op == "SC" || op == "SCN";
        auto space = stroke ? colors.stroke : colors.fill;
        if (op == "g" || op == "G") space = colorSpace("/DeviceGray");
        if (op == "rg" || op == "RG") space = colorSpace("/DeviceRGB");
        if (op == "k" || op == "K") space = colorSpace("/DeviceCMYK");
        (stroke ? colors.stroke : colors.fill) = space;
        if (values.size() != space.initial.size()) throw std::runtime_error("Invalid color component count");
        bool generic = op == "sc" || op == "SC" || op == "scn" || op == "SCN";
        auto original = (generic ? space.selection + (stroke ? " CS\n" : " cs\n") : "") + pending + " " + op + "\n";
        (stroke ? colors.originalStroke : colors.originalFill) = original;
        return mappedColor(space, values, original, stroke);
    }
    std::string mappedColor(DrawingColorSpace space, std::vector<double> const& values,
                            std::string const& original, bool stroke) {
        // /None deliberately paints nothing; replacing it with gray would make
        // invisible printer marks visible. Preserve all-None DeviceN as well.
        auto definition = space.definition;
        if (definition.isArray()) {
            auto kind = definition.getArrayItem(0), names = definition.getArrayItem(1);
            if (kind.isNameAndEquals("/Separation") && names.isNameAndEquals("/None")) return original;
            if (kind.isNameAndEquals("/DeviceN") && names.isArray()) {
                bool allNone = true;
                for (int i = 0; i < names.getArrayNItems(); ++i) allNone &= names.getArrayItem(i).isNameAndEquals("/None");
                if (allNone) return original;
            }
        }
        auto [r, g, b] = converter.rgb(space, values);
        if (std::max({r,g,b}) - std::min({r,g,b}) > 0.025) return original;
        double value = 0.90 - (0.90 - 36.0/255.0) * (r+g+b)/3;
        std::ostringstream out;
        out << value << (stroke ? " G\n" : " g\n");
        return out.str();
    }
    void backdrop(Rectangle rect = {}, Matrix matrix = {}) {
        if (path) throw std::runtime_error("Image inside an unfinished drawing path");
        if (colors.fillAlpha == 0) return;
        std::string reset;
        if (colors.fillAlpha != 1) {
            if (opaqueBackdrop.empty()) {
                auto states = resources.getKey("/ExtGState");
                states = states.isDictionary() ? states.shallowCopy() : Object::newDictionary();
                opaqueBackdrop = "/APDFOpaqueImageBackdrop";
                while (states.hasKey(opaqueBackdrop)) opaqueBackdrop += "x";
                auto state = Object::newDictionary();
                state.replaceKey("/ca", Object::newInteger(1));
                states.replaceKey(opaqueBackdrop, state);
                resources.replaceKey("/ExtGState", states);
            }
            reset = opaqueBackdrop + " gs ";
        }
        // Make only the backing opaque. Q restores the image's own alpha, so
        // translucent images retain their original white-paper appearance.
        std::ostringstream out;
        out << std::setprecision(17) << "q " << reset << "1 1 1 rg "
            << matrix.a << " " << matrix.b << " " << matrix.c << " " << matrix.d << " " << matrix.e << " " << matrix.f << " cm "
            << rect.x << " " << rect.y << " " << rect.width << " " << rect.height << " re f Q\n";
        write(out.str());
    }
    void checkGraphicsState(Object state) {
        if (!state.isDictionary()) throw std::runtime_error("Missing graphics state");
        for (auto key : {"/ca", "/CA"}) {
            auto a = state.getKey(key);
            if (!a.isNull()) {
                if (!a.isNumber() || !std::isfinite(a.getNumericValue()) || a.getNumericValue() < 0 || a.getNumericValue() > 1)
                    throw std::runtime_error("Invalid transparency value: retain original page");
                (std::string(key) == "/ca" ? colors.fillAlpha : colors.strokeAlpha) = a.getNumericValue();
            }
        }
        for (auto key : {"/SMask", "/BM", "/TR", "/TR2"}) {
            auto value = state.getKey(key);
            if (!value.isNull() && !value.isNameAndEquals("/None") &&
                !value.isNameAndEquals("/Normal") && !value.isNameAndEquals("/Identity") &&
                !value.isNameAndEquals("/Default"))
                throw std::runtime_error("Complex compositing: retain original page");
        }
    }
    std::string drawObject() {
        if (operands.size() != 1 || operands[0].getType() != QPDFTokenizer::tt_name)
            throw std::runtime_error("Invalid XObject invocation");
        auto objects = resources.getKey("/XObject");
        auto object = objects.getKey(operands[0].getValue());
        if (!object.isStream()) throw std::runtime_error("Missing XObject");
        auto dict = object.getDict();
        if (dict.getKey("/Subtype").isNameAndEquals("/Image")) {
            if (dict.getKey("/ImageMask").isBool() && dict.getKey("/ImageMask").getBoolValue())
                throw std::runtime_error("Stencil image: retain original page");
            // An opaque white backing preserves transparent image edge colors
            // on ordinary white-paper PDFs, including image /SMask alpha.
            backdrop();
        } else if (dict.getKey("/Subtype").isNameAndEquals("/Form")) {
            auto bounds = Rectangle::read(dict.getKey("/BBox"));
            auto matrix = Matrix::read(dict.getKey("/Matrix"));
            auto transform = colors.transform.then(matrix);
            auto footprint = bounds.transformed(transform);
            // A bounded Form is a complete graphic, including its own labels,
            // paths, charts and nested images. Preserve that entire object on
            // white paper instead of guessing which parts are body text.
            // Page-sized wrappers are traversed so their body can still darken.
            bool pageWrapper = footprint.width >= pageBounds.width * 0.98 &&
                               footprint.height >= pageBounds.height * 0.98;
            if (!pageWrapper) {
                backdrop(bounds, matrix);
                return "q\n" + colors.originalFill + colors.originalStroke + operands[0].getRawValue() + " Do\nQ\n";
            }
            auto nested = ancestors;
            if (depth >= 24 || !nested.insert(object.getObjGen()).second)
                throw std::runtime_error("Recursive form graph");
            auto formResources = dict.getKey("/Resources");
            if (formResources.isNull()) formResources = resources;
            auto initial = colors;
            initial.transform = transform;
            DarkTokens filter(pdf, converter, formResources, initial, depth+1, budget, pageBounds, nested);
            Pl_Buffer buffer("dark form");
            object.filterAsContents(&filter, &buffer);
            filter.checkSupported();
            auto bytes = buffer.getBufferSharedPointer();
            auto clone = object.copyStream();
            clone.replaceStreamData(std::string((char const*)bytes->getBuffer(), bytes->getSize()), Object::newNull(), Object::newNull());
            clone.getDict().replaceKey("/Resources", filter.getResources());
            // Keep original aliases as well; all image and font objects remain
            // unmodified. A fresh alias handles forms invoked with new state.
            std::string alias = "/APDFDarkForm" + std::to_string(++budget);
            while (objects.hasKey(alias)) alias += "x";
            objects.replaceKey(alias, clone);
            resources.replaceKey("/XObject", objects);
            return alias + " Do\n";
        } else throw std::runtime_error("Unsupported XObject subtype");
        return "";
    }
  public:
    DarkTokens(QPDF& pdf, DisplayColorConverter& converter, Object resource, DrawingState initial, int depth, size_t& budget, Rectangle pageBounds,
               std::set<QPDFObjGen> ancestors = {}) : pdf(pdf), converter(converter), colors(initial), pageBounds(pageBounds), depth(depth), budget(budget), ancestors(ancestors) {
        resources = resource.isDictionary() ? resource.shallowCopy() : Object::newDictionary();
        auto objects = resources.getKey("/XObject");
        if (objects.isDictionary()) resources.replaceKey("/XObject", objects.shallowCopy());
    }
    Object getResources() { return resources; }
    void checkSupported() const {
        if (!failure.empty()) throw std::runtime_error(failure);
    }
    void handleToken(Token const& token) override {
        // QPDF treats exceptions from a token callback as damaged stream data.
        // Defer our intentional unsupported-feature errors until the pipeline
        // finishes, so one fallback page cannot disable every other page.
        if (!failure.empty()) return;
        try { transformToken(token); }
        catch (std::exception const& error) { failure = error.what(); }
    }
    void transformToken(Token const& token) {
        if (++budget > 8000000) throw std::runtime_error("Display transformation exceeds token budget");
        auto type = token.getType();
        if (type == QPDFTokenizer::tt_bad) throw std::runtime_error("Malformed content token");
        if (type == QPDFTokenizer::tt_eof) { write(pending); pending.clear(); return; }
        if (inlineImage) {
            if (type == QPDFTokenizer::tt_name)
                inlineMaskKey = token.getValue() == "/IM" || token.getValue() == "/ImageMask";
            else if (inlineMaskKey && type == QPDFTokenizer::tt_bool && token.getValue() == "true")
                throw std::runtime_error("Inline stencil image: retain original page");
            writeToken(token);
            if (token.isWord("EI")) inlineImage = false;
            return;
        }
        if (type == QPDFTokenizer::tt_word) {
            auto op = token.getValue();
            std::string replacement;
            if (op == "g" || op == "G" || op == "rg" || op == "RG" || op == "k" || op == "K" ||
                op == "sc" || op == "SC" || op == "scn" || op == "SCN") replacement = neutral(op);
            else if (op == "cs" || op == "CS") {
                if (operands.size() != 1) throw std::runtime_error("Invalid color space operator");
                auto space = colorSpace(operands[0].getValue());
                bool stroke = op == "CS";
                (stroke ? colors.stroke : colors.fill) = space;
                std::ostringstream initial;
                for (double value : space.initial) initial << value << " ";
                auto original = space.selection + " " + op + "\n" + initial.str() + (stroke ? "SCN\n" : "scn\n");
                (stroke ? colors.originalStroke : colors.originalFill) = original;
                replacement = mappedColor(space, space.initial, original, stroke);
            } else if (op == "cm") {
                if (operands.size() != 6) throw std::runtime_error("Invalid transformation operator");
                double v[6];
                for (int i = 0; i < 6; ++i) {
                    auto type = operands[i].getType();
                    if (type != QPDFTokenizer::tt_integer && type != QPDFTokenizer::tt_real)
                        throw std::runtime_error("Invalid transformation operand");
                    v[i] = std::stod(operands[i].getValue());
                    if (!std::isfinite(v[i])) throw std::runtime_error("Invalid transformation operand");
                }
                colors.transform = colors.transform.then({v[0], v[1], v[2], v[3], v[4], v[5]});
            } else if (op == "q") stack.push_back(colors);
            else if (op == "Q") {
                if (stack.empty()) throw std::runtime_error("Unbalanced graphics state");
                colors = stack.back(); stack.pop_back();
            } else if (op == "gs") {
                if (operands.size() != 1) throw std::runtime_error("Invalid graphics state operator");
                checkGraphicsState(resources.getKey("/ExtGState").getKey(operands[0].getValue()));
            } else if (op == "Do") replacement = drawObject();
            else if (op == "BI") { backdrop(); inlineImage = true; }
            if (op == "m" || op == "l" || op == "c" || op == "v" || op == "y" || op == "re") path = true;
            if (op == "S" || op == "s" || op == "f" || op == "F" || op == "f*" || op == "B" ||
                op == "B*" || op == "b" || op == "b*" || op == "n") path = false;
            if (replacement.empty()) { write(pending); writeToken(token); }
            else write(replacement);
            write("\n"); pending.clear(); operands.clear();
        } else {
            pending += token.getRawValue();
            if (type != QPDFTokenizer::tt_space && type != QPDFTokenizer::tt_comment) operands.push_back(token);
        }
    }
};
}

NSDictionary *APDFCreateImagePreservingDisplay(NSData *data, NSError **error) {
    try {
        QPDF pdf;
        pdf.setSuppressWarnings(true);
        pdf.processMemoryFile("display-source.pdf", (char const*)data.bytes, data.length);
        if (pdf.isEncrypted()) throw std::runtime_error("Encrypted PDF: image-preserving dark display unavailable");
        auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
        NSMutableArray *supported = [NSMutableArray array], *reasons = [NSMutableArray array];
        size_t budget = 0;
        DisplayColorConverter converter(pdf);
        for (auto& page : pages) {
            bool success = false;
            NSString *reason = @"";
            try {
                auto box = page.getMediaBox();
                DarkTokens filter(pdf, converter, page.getAttribute("/Resources", false), DrawingState{}, 0, budget, Rectangle::read(box));
                Pl_Buffer stream("dark page");
                page.filterContents(&filter, &stream);
                filter.checkSupported();
                auto buffer = stream.getBufferSharedPointer();
                double x = box.getArrayItem(0).getNumericValue(), y = box.getArrayItem(1).getNumericValue();
                double w = box.getArrayItem(2).getNumericValue()-x, h = box.getArrayItem(3).getNumericValue()-y;
                std::ostringstream prefix;
                prefix << "q 0.14117647 g " << x << " " << y << " " << w << " " << h << " re f Q\n0.9 g 0.9 G\n";
                auto content = Object::newStream(&pdf, prefix.str() + std::string((char const*)buffer->getBuffer(), buffer->getSize()));
                auto dict = page.getObjectHandle();
                dict.replaceKey("/Contents", content);
                dict.replaceKey("/Resources", filter.getResources());
                success = true;
            } catch (std::exception const& failure) { reason = [NSString stringWithUTF8String:failure.what()] ?: @"Unsupported page"; }
            // Annotations remain live in the original PDFView document.
            page.getObjectHandle().removeKey("/Annots");
            [supported addObject:@(success)]; [reasons addObject:reason];
        }
        // Copy encoded image bytes without recompression, including their masks,
        // profiles, decode arrays and original interpolation settings.
        for (auto object : pdf.getAllObjects())
            if (object.isStream() && object.getDict().getKey("/Subtype").isNameAndEquals("/Image")) object.setFilterOnWrite(false);
        QPDFWriter writer(pdf);
        writer.setOutputMemory(); writer.setStreamDataMode(qpdf_s_preserve); writer.write();
        if (pdf.anyWarnings()) throw std::runtime_error("PDF warnings: retain original display");
        auto buffer = writer.getBufferSharedPointer();
        return @{@"data": [NSData dataWithBytes:buffer->getBuffer() length:buffer->getSize()],
                 @"supported": supported, @"reasons": reasons};
    } catch (std::exception const& failure) {
        if (error) *error = [NSError errorWithDomain:@"AdaptivePDF.ImagePreservingDisplay" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()] ?: @"Display preparation failed"}];
        return nil;
    }
}
