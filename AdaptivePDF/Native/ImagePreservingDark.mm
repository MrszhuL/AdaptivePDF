#import "QPDFBridge.h"
#import <CoreGraphics/CoreGraphics.h>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pl_Buffer.hh>
#include <algorithm>
#include <charconv>
#include <cmath>
#include <memory>
#include <optional>
#include <stdexcept>
#include <set>
#include <map>
#include <array>

namespace {
using Object = QPDFObjectHandle;
using Token = QPDFTokenizer::Token;

std::string pdfNumber(double value) {
    // The shortest round-trippable fixed decimal. PDF has no exponent syntax.
    if (!std::isfinite(value)) throw std::runtime_error("Non-finite display coordinate");
    char buffer[384];
    auto result = std::to_chars(std::begin(buffer), std::end(buffer), value, std::chars_format::fixed);
    if (result.ec != std::errc{}) throw std::runtime_error("Cannot encode display coordinate");
    return {buffer, result.ptr};
}

using Path = std::shared_ptr<const CGPath>;
Path ownPath(CGPathRef path) {
    if (!path) throw std::runtime_error("Cannot construct figure clipping path");
    return Path(path, CGPathRelease);
}

std::string pdfPath(Path const& path) {
    __block std::string output;
    __block CGPoint current = {}, start = {};
    CGPathApplyWithBlock(path.get(), ^(const CGPathElement *element) {
        auto point = [](CGPoint p) { return pdfNumber(p.x) + " " + pdfNumber(p.y) + " "; };
        auto& stream = output;
        auto p = element->points;
        switch (element->type) {
            case kCGPathElementMoveToPoint: stream += point(p[0]) + "m\n"; current = start = p[0]; break;
            case kCGPathElementAddLineToPoint: stream += point(p[0]) + "l\n"; current = p[0]; break;
            case kCGPathElementAddQuadCurveToPoint: {
                CGPoint c1 = {current.x + (p[0].x-current.x)*2/3, current.y + (p[0].y-current.y)*2/3};
                CGPoint c2 = {p[1].x + (p[0].x-p[1].x)*2/3, p[1].y + (p[0].y-p[1].y)*2/3};
                stream += point(c1) + point(c2) + point(p[1]) + "c\n";
                current = p[1]; break;
            }
            case kCGPathElementAddCurveToPoint: stream += point(p[0]) + point(p[1]) + point(p[2]) + "c\n"; current = p[2]; break;
            case kCGPathElementCloseSubpath: stream += "h\n"; current = start; break;
        }
    });
    return output;
}
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
        std::string operands;
        for (double value : values) operands += pdfNumber(value) + " ";
        auto key = definition.unparse() + ":" + operands;
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
        page.replaceKey("/Contents", Object::newStream(&probe, "/Sample cs " + operands + "scn 0 0 2 2 re f\n"));
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
            CGBitmapInfo(kCGImageAlphaPremultipliedLast) | kCGBitmapByteOrder32Big);
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
    CGAffineTransform affine() const {
        for (double value : {a, b, c, d, e, f}) {
            if (!std::isfinite(value)) throw std::runtime_error("Invalid drawing transform");
        }
        return CGAffineTransformMake(a, b, c, d, e, f);
    }
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
    CGRect cgRect() const { return CGRectMake(x, y, width, height); }
    std::string pdfRect() const {
        return pdfNumber(x) + " " + pdfNumber(y) + " " + pdfNumber(width) + " " + pdfNumber(height) + " re ";
    }
};

Path intersect(Path const& path, Path const& clip) {
    return clip ? ownPath(CGPathCreateCopyByIntersectingPath(path.get(), clip.get(), false)) : path;
}

class FigureRegions {
    // Merge in batches so a page with many figures doesn't repeatedly union
    // each new rectangle with every previously collected outline.
    std::vector<Path> levels;
    size_t count = 0;
  public:
    bool hasTextClip = false;
    void add(Path region) {
        if (CGPathIsEmpty(region.get())) return;
        if (++count > 4096) throw std::runtime_error("Figure clipping exceeds the display budget");
        for (auto& level : levels) {
            if (!level) { level = std::move(region); return; }
            region = ownPath(CGPathCreateCopyByUnioningPath(level.get(), region.get(), false));
            level.reset();
        }
        levels.push_back(std::move(region));
    }
    Path combined() const {
        if (count && hasTextClip) throw std::runtime_error("Text clipping overlaps potential figure regions");
        Path result;
        for (auto const& level : levels) {
            if (level) result = result ? ownPath(CGPathCreateCopyByUnioningPath(result.get(), level.get(), false)) : level;
        }
        return result;
    }
};

struct DrawingState {
    DrawingColorSpace fill, stroke;
    double fillAlpha = 1;
    Matrix transform;
    Path clip;
};

// Lexical tokens keep strings, comments and binary inline images out of the
// operator parser. This filter is never attached to the original live PDF.
class DarkTokens final : public Object::TokenFilter {
    QPDF& pdf;
    DisplayColorConverter& converter;
    Object resources;
    DrawingState colors;
    Rectangle pageBounds;
    FigureRegions& figures;
    std::vector<DrawingState> stack;
    std::vector<Token> operands;
    std::string pending;
    std::string failure;
    std::shared_ptr<CGPath> path;
    bool inlineImage = false, inlineMaskKey = false;
    std::optional<bool> clipRule;
    int depth;
    size_t& budget;
    BOOL (^shouldCancel)(void);
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
        return pdfNumber(value) + (stroke ? " G\n" : " g\n");
    }
    double operand(size_t index) const {
        auto const& token = operands.at(index);
        auto type = token.getType();
        if (type != QPDFTokenizer::tt_integer && type != QPDFTokenizer::tt_real)
            throw std::runtime_error("Invalid drawing operand");
        double value = std::stod(token.getValue());
        if (!std::isfinite(value)) throw std::runtime_error("Invalid drawing operand");
        return value;
    }
    CGPoint point(double x, double y) const {
        auto p = CGPointApplyAffineTransform(CGPointMake(x, y), colors.transform.affine());
        if (!std::isfinite(p.x) || !std::isfinite(p.y)) throw std::runtime_error("Invalid transformed drawing point");
        return p;
    }
    void trackPath(std::string const& op) {
        if (op == "W" || op == "W*") {
            clipRule = op == "W*";
        } else if (op == "S" || op == "s" || op == "f" || op == "F" || op == "f*" || op == "B" ||
                   op == "B*" || op == "b" || op == "b*" || op == "n") {
            if (clipRule) {
                auto clip = path ? ownPath(CGPathCreateCopyByNormalizing(path.get(), *clipRule)) :
                    ownPath(CGPathCreateMutable());
                colors.clip = intersect(clip, colors.clip);
            }
            clipRule.reset();
            path.reset();
        } else if (op == "m" || op == "l" || op == "c" || op == "v" || op == "y" || op == "re" || op == "h") {
            if (!path) path = std::shared_ptr<CGPath>(CGPathCreateMutable(), CGPathRelease);
            if (op == "h") { CGPathCloseSubpath(path.get()); return; }
            auto p = point(operand(0), operand(1));
            if (op == "m") CGPathMoveToPoint(path.get(), nullptr, p.x, p.y);
            else if (op == "l") CGPathAddLineToPoint(path.get(), nullptr, p.x, p.y);
            else if (op == "re") {
                double x = operand(0), y = operand(1), w = operand(2), h = operand(3);
                CGPathMoveToPoint(path.get(), nullptr, p.x, p.y);
                for (auto corner : {point(x+w,y), point(x+w,y+h), point(x,y+h)})
                    CGPathAddLineToPoint(path.get(), nullptr, corner.x, corner.y);
                CGPathCloseSubpath(path.get());
            } else {
                auto next = point(operand(2), operand(3));
                if (op == "v") {
                    auto current = CGPathGetCurrentPoint(path.get());
                    CGPathAddCurveToPoint(path.get(), nullptr, current.x, current.y, p.x, p.y, next.x, next.y);
                } else {
                    auto end = op == "y" ? next : point(operand(4), operand(5));
                    CGPathAddCurveToPoint(path.get(), nullptr, p.x, p.y, next.x, next.y, end.x, end.y);
                }
            }
        }
    }
    void keepFigure(Path const& region) {
        if (path) throw std::runtime_error("Image inside an unfinished drawing path");
        figures.add(intersect(region, colors.clip));
    }
    void checkGraphicsState(Object state) {
        if (!state.isDictionary()) throw std::runtime_error("Missing graphics state");
        for (auto key : {"/ca", "/CA"}) {
            auto a = state.getKey(key);
            if (!a.isNull()) {
                if (!a.isNumber() || !std::isfinite(a.getNumericValue()) || a.getNumericValue() < 0 || a.getNumericValue() > 1)
                    throw std::runtime_error("Invalid transparency value: retain original page");
                if (key[2] == 'a') colors.fillAlpha = a.getNumericValue();
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
            auto embeddedMask = dict.getKey("/SMaskInData");
            if (colors.fillAlpha > 0 && (colors.fillAlpha < 1 || !dict.getKey("/SMask").isNull() ||
                !dict.getKey("/Mask").isNull() || (embeddedMask.isInteger() && embeddedMask.getIntValue() != 0))) {
                auto transform = colors.transform.affine();
                keepFigure(ownPath(CGPathCreateWithRect(CGRectMake(0, 0, 1, 1), &transform)));
                return "\n"; // the original page draws the image in its original layer order
            }
        } else if (dict.getKey("/Subtype").isNameAndEquals("/Form")) {
            auto bounds = Rectangle::read(dict.getKey("/BBox"));
            auto matrix = Matrix::read(dict.getKey("/Matrix"));
            auto transform = colors.transform.then(matrix);
            auto affine = transform.affine();
            auto footprint = CGRectApplyAffineTransform(bounds.cgRect(), affine);
            // A bounded Form is a complete graphic, including its own labels,
            // paths, charts and nested images. Preserve that entire object on
            // white paper instead of guessing which parts are body text.
            // Page-sized wrappers are traversed so their body can still darken.
            bool pageWrapper = footprint.size.width >= pageBounds.width * 0.98 &&
                               footprint.size.height >= pageBounds.height * 0.98;
            auto region = ownPath(CGPathCreateWithRect(bounds.cgRect(), &affine));
            if (!pageWrapper) {
                keepFigure(region);
                return "\n";
            }
            auto nested = ancestors;
            if (depth >= 24 || !nested.insert(object.getObjGen()).second)
                throw std::runtime_error("Recursive form graph");
            auto formResources = dict.getKey("/Resources");
            if (formResources.isNull()) formResources = resources;
            auto initial = colors;
            initial.transform = transform;
            initial.clip = intersect(region, colors.clip);
            DarkTokens filter(pdf, converter, formResources, initial, depth+1, budget, pageBounds, figures, shouldCancel, nested);
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
    DarkTokens(QPDF& pdf, DisplayColorConverter& converter, Object resource, DrawingState initial, int depth,
               size_t& budget, Rectangle pageBounds, FigureRegions& figures, BOOL (^shouldCancel)(void),
               std::set<QPDFObjGen> ancestors = {}) :
        pdf(pdf), converter(converter), colors(initial), pageBounds(pageBounds), figures(figures),
        depth(depth), budget(budget), shouldCancel(shouldCancel), ancestors(ancestors) {
        resources = resource.isDictionary() ? resource.shallowCopy() : Object::newDictionary();
        auto objects = resources.getKey("/XObject");
        if (objects.isDictionary()) resources.replaceKey("/XObject", objects.shallowCopy());
    }
    Object getResources() { return resources; }
    void checkSupported() const {
        if (!failure.empty()) throw std::runtime_error(failure);
        if (!stack.empty()) throw std::runtime_error("Unbalanced graphics state");
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
        if (shouldCancel && (budget & 1023) == 0 && shouldCancel())
            throw std::runtime_error("Display preparation cancelled");
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
                std::string initial;
                for (double value : space.initial) initial += pdfNumber(value) + " ";
                auto original = space.selection + " " + op + "\n" + initial + (stroke ? "SCN\n" : "scn\n");
                replacement = mappedColor(space, space.initial, original, stroke);
            } else if (op == "cm") {
                if (operands.size() != 6) throw std::runtime_error("Invalid transformation operator");
                double v[6];
                for (int i = 0; i < 6; ++i) v[i] = operand(i);
                colors.transform = colors.transform.then({v[0], v[1], v[2], v[3], v[4], v[5]});
            } else if (op == "q") {
                if (stack.size() >= 256) throw std::runtime_error("Graphics state stack exceeds the display budget");
                stack.push_back(colors);
            }
            else if (op == "Q") {
                if (stack.empty()) throw std::runtime_error("Unbalanced graphics state");
                colors = stack.back(); stack.pop_back();
            } else if (op == "gs") {
                if (operands.size() != 1) throw std::runtime_error("Invalid graphics state operator");
                checkGraphicsState(resources.getKey("/ExtGState").getKey(operands[0].getValue()));
            } else if (op == "Do") replacement = drawObject();
            else if (op == "BI") {
                if (colors.fillAlpha > 0 && colors.fillAlpha < 1) {
                    auto transform = colors.transform.affine();
                    keepFigure(ownPath(CGPathCreateWithRect(CGRectMake(0, 0, 1, 1), &transform)));
                }
                inlineImage = true;
            } else if (op == "Tr" && operand(0) >= 4) {
                figures.hasTextClip = true;
            }
            trackPath(op);
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

NSDictionary *APDFCreateCancellableDisplay(NSData *data, NSRange range, BOOL (^shouldCancel)(void), NSError **error) {
    try {
        QPDF source, subset;
        source.setSuppressWarnings(true);
        source.processMemoryFile("display-source.pdf", (char const*)data.bytes, data.length);
        if (source.isEncrypted()) throw std::runtime_error("Encrypted PDF: image-preserving dark display unavailable");
        if (shouldCancel()) return nil;
        if (range.length) {
            auto const& originals = source.getAllPages();
            if (range.location >= originals.size() || range.length > originals.size() - range.location)
                throw std::runtime_error("Display page range is outside the document");
            subset.setSuppressWarnings(true);
            subset.emptyPDF();
            QPDFPageDocumentHelper target(subset);
            for (size_t index = range.location; index < NSMaxRange(range); ++index) {
                if (shouldCancel()) return nil;
                auto page = originals[index];
                page.removeKey("/Annots");
                target.addPage(QPDFPageObjectHelper(page), false);
            }
            // Keep document-level color and optional-layer settings used by
            // imported image resources and drawing instructions.
            for (auto key : {"/OCProperties", "/OutputIntents"}) {
                auto entry = source.getRoot().getKey(key);
                if (!entry.isNull()) {
                    if (!entry.isIndirect()) entry = source.makeIndirectObject(entry);
                    subset.getRoot().replaceKey(key, subset.copyForeignObject(entry));
                }
            }
        }
        QPDF& pdf = range.length ? subset : source;
        auto pages = QPDFPageDocumentHelper(pdf).getAllPages();
        NSMutableArray *supported = [NSMutableArray array], *reasons = [NSMutableArray array];
        size_t budget = 0;
        DisplayColorConverter converter(pdf);
        for (auto& page : pages) {
            if (shouldCancel()) return nil;
            if (budget > 8000000) {
                [supported addObject:@NO];
                [reasons addObject:@"Display transformation exceeds token budget"];
                page.getObjectHandle().removeKey("/Annots");
                continue;
            }
            bool success = false;
            NSString *reason = @"";
            try {
                auto box = page.getMediaBox();
                auto bounds = Rectangle::read(box);
                auto paper = bounds.pdfRect();
                FigureRegions figures;
                DarkTokens filter(pdf, converter, page.getAttribute("/Resources", false), DrawingState{}, 0, budget, bounds, figures, shouldCancel);
                Pl_Buffer stream("dark page");
                page.filterContents(&filter, &stream);
                filter.checkSupported();
                auto buffer = stream.getBufferSharedPointer();
                auto resources = filter.getResources();
                std::string content = "q 0.14117647 g " + paper + "f 0.9 g 0.9 G\n";
                if (buffer->getSize()) content.append((char const*)buffer->getBuffer(), buffer->getSize());
                content += "\nQ\n";
                if (auto region = figures.combined()) {
                    // Repaint the protected region once using the original layer order.
                    // This keeps transparency over other drawing, including vector backgrounds.
                    // qpdf reads the Form's source stream lazily when it writes
                    // the display copy. Keep a separate page dictionary there.
                    auto original = page.shallowCopyPage().getFormXObjectForPage(false);
                    original.getDict().replaceKey("/BBox", box);
                    auto objects = resources.getKey("/XObject");
                    if (!objects.isDictionary()) objects = Object::newDictionary();
                    std::string name = "/APDFOriginalFigureLayers";
                    while (objects.hasKey(name)) name += "x";
                    objects.replaceKey(name, original);
                    resources.replaceKey("/XObject", objects);
                    content += "q\n" + pdfPath(region) + "W n\n1 g " + paper + "f\n0 g 0 G\n" + name + " Do\nQ\n";
                }
                auto dict = page.getObjectHandle();
                dict.replaceKey("/Contents", Object::newStream(&pdf, content));
                dict.replaceKey("/Resources", resources);
                success = true;
            } catch (std::exception const& failure) { reason = [NSString stringWithUTF8String:failure.what()] ?: @"Unsupported page"; }
            // Annotations remain live in the original PDFView document.
            page.getObjectHandle().removeKey("/Annots");
            [supported addObject:@(success)]; [reasons addObject:reason];
        }
        if (shouldCancel()) return nil;
        // Copy encoded image bytes without recompression, including their masks,
        // profiles, decode arrays and original interpolation settings.
        size_t objectIndex = 0;
        for (auto object : pdf.getAllObjects()) {
            if ((++objectIndex & 127) == 0 && shouldCancel()) return nil;
            if (object.isStream() && object.getDict().getKey("/Subtype").isNameAndEquals("/Image")) object.setFilterOnWrite(false);
        }
        QPDFWriter writer(pdf);
        if (range.length) writer.setMinimumPDFVersion(source.getPDFVersion());
        writer.setOutputMemory();
        writer.setStreamDataMode(qpdf_s_preserve);
        writer.registerProgressReporter(std::make_shared<QPDFWriter::FunctionProgressReporter>([shouldCancel](int) {
            if (shouldCancel()) throw std::runtime_error("Display preparation cancelled");
        }));
        writer.write();
        if (pdf.anyWarnings() || source.anyWarnings()) throw std::runtime_error("PDF warnings: retain original display");
        auto buffer = writer.getBufferSharedPointer();
        // NSData owns the qpdf allocation for as long as Core Graphics needs it.
        NSData *bytes = [[NSData alloc] initWithBytesNoCopy:buffer->getBuffer() length:buffer->getSize()
            deallocator:^(void *, NSUInteger) { (void)buffer; }];
        return @{@"data": bytes, @"supported": supported, @"reasons": reasons};
    } catch (std::exception const& failure) {
        if (shouldCancel()) return nil;
        if (error) *error = [NSError errorWithDomain:@"AdaptivePDF.ImagePreservingDisplay" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()] ?: @"Display preparation failed"}];
        return nil;
    }
}

NSDictionary *APDFCreateImagePreservingDisplay(NSData *data, NSError **error) {
    return APDFCreateCancellableDisplay(data, NSMakeRange(0, 0), ^BOOL { return NO; }, error);
}
