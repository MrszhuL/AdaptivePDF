#import "QPDFBridge.h"
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

namespace {
using Object = QPDFObjectHandle;
using Token = QPDFTokenizer::Token;
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
    std::string fill = "/DeviceGray", stroke = "/DeviceGray";
    std::string originalFill = "0 g\n", originalStroke = "0 G\n";
    double fillAlpha = 1, strokeAlpha = 1;
    Matrix transform;
};

// Lexical tokens keep strings, comments and binary inline images out of the
// operator parser. This filter is never attached to the original live PDF.
class DarkTokens final : public Object::TokenFilter {
    QPDF& pdf;
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
    std::string colorSpace(std::string name) {
        if (name == "/DeviceGray" || name == "/DeviceRGB" || name == "/DeviceCMYK") return name;
        auto dictionary = resources.getKey("/ColorSpace");
        if (!dictionary.isDictionary()) throw std::runtime_error("Missing drawing color space");
        auto value = dictionary.getKey(name);
        if (value.isName()) {
            name = value.getName();
            if (name == "/DeviceGray" || name == "/DeviceRGB" || name == "/DeviceCMYK") return name;
        } else if (value.isArray() && value.getArrayNItems() >= 2) {
            auto kind = value.getArrayItem(0);
            if (kind.isNameAndEquals("/CalGray")) return "/DeviceGray";
            if (kind.isNameAndEquals("/CalRGB")) return "/DeviceRGB";
            if (kind.isNameAndEquals("/ICCBased")) {
                auto profile = value.getArrayItem(1);
                if (profile.isStream()) {
                    auto count = profile.getDict().getKey("/N");
                    if (count.isInteger()) {
                        if (count.getIntValue() == 1) return "/DeviceGray";
                        if (count.getIntValue() == 3) return "/DeviceRGB";
                        if (count.getIntValue() == 4) return "/DeviceCMYK";
                    }
                }
            }
        }
        throw std::runtime_error("Special drawing color space: retain original page");
    }
    std::string neutral(std::string const& op) {
        std::vector<double> values;
        for (auto const& t : operands) {
            if (t.getType() != QPDFTokenizer::tt_integer && t.getType() != QPDFTokenizer::tt_real) return "";
            double x = std::stod(t.getValue());
            if (!std::isfinite(x) || x < 0 || x > 1) return "";
            values.push_back(x);
        }
        bool stroke = op == "G" || op == "RG" || op == "K" || op == "SC" || op == "SCN";
        (stroke ? colors.originalStroke : colors.originalFill) = pending + " " + op + "\n";
        std::string space = stroke ? colors.stroke : colors.fill;
        if (op == "g" || op == "G") space = "/DeviceGray";
        if (op == "rg" || op == "RG") space = "/DeviceRGB";
        if (op == "k" || op == "K") space = "/DeviceCMYK";
        (stroke ? colors.stroke : colors.fill) = space;
        double r, g, b;
        if (space == "/DeviceGray" && values.size() == 1) r = g = b = values[0];
        else if (space == "/DeviceRGB" && values.size() == 3) { r = values[0]; g = values[1]; b = values[2]; }
        else if (space == "/DeviceCMYK" && values.size() == 4) {
            r = (1-values[0])*(1-values[3]); g = (1-values[1])*(1-values[3]); b = (1-values[2])*(1-values[3]);
        } else throw std::runtime_error("Unsupported drawing color space");
        if (std::max({r,g,b}) - std::min({r,g,b}) > 0.025) return "";
        double value = 0.90 - (0.90 - 36.0/255.0) * (r+g+b)/3;
        // Keep the original color space active for subsequent SC/SCN operators.
        std::ostringstream out;
        bool generic = op == "sc" || op == "SC" || op == "scn" || op == "SCN";
        if (space == "/DeviceGray") out << value << " " << (generic ? op : stroke ? "G" : "g") << "\n";
        else if (space == "/DeviceRGB") out << value << " " << value << " " << value << " " << (generic ? op : stroke ? "RG" : "rg") << "\n";
        else out << "0 0 0 " << 1-value << " " << (generic ? op : stroke ? "K" : "k") << "\n";
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
            DarkTokens filter(pdf, formResources, initial, depth+1, budget, pageBounds, nested);
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
    DarkTokens(QPDF& pdf, Object resource, DrawingState initial, int depth, size_t& budget, Rectangle pageBounds,
               std::set<QPDFObjGen> ancestors = {}) : pdf(pdf), colors(initial), pageBounds(pageBounds), depth(depth), budget(budget), ancestors(ancestors) {
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
                std::string name = colorSpace(operands[0].getValue());
                (op == "cs" ? colors.fill : colors.stroke) = name;
                // Changing a color space resets its initial color to black.
                std::string value = name == "/DeviceGray" ? "0.9" : name == "/DeviceRGB" ? "0.9 0.9 0.9" : "0 0 0 0.1";
                std::string original = name == "/DeviceGray" ? "0" : name == "/DeviceRGB" ? "0 0 0" : "0 0 0 1";
                (op == "cs" ? colors.originalFill : colors.originalStroke) = pending + " " + op + "\n" + original + (op == "cs" ? " sc\n" : " SC\n");
                replacement = pending + " " + op + "\n" + value + (op == "cs" ? " sc\n" : " SC\n");
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
        for (auto& page : pages) {
            bool success = false;
            NSString *reason = @"";
            try {
                auto box = page.getMediaBox();
                DarkTokens filter(pdf, page.getAttribute("/Resources", false), DrawingState{}, 0, budget, Rectangle::read(box));
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
