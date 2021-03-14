using FreeTypeAbstraction
using GeometryBasics
using MathTeXParser

import FreeTypeAbstraction:
    ascender, descender, get_extent, hadvance, inkheight, inkwidth,
    leftinkbound, rightinkbound, topinkbound, bottominkbound

include("symbols.jl")

# Positions (resp. scales) are positions of the elements relative to the parent
# Absolute pos and scales will get computed when all gets flattened
struct Group
    elements::Vector
    positions::Vector{Point2f0}
    scales::Vector
end

function advance(g::Group)
    adv = xpositions(g) .+ advance.(g.elements) .* g.scales
    return maximum(adv)
end

function ascender(g::Group)
    asc = ypositions(g) .+ ascender.(g.elements) .* g.scales
    return maximum(asc)
end

# Offset of the ink relative to the baseline 
yoffset(g::Group) = 0
xpositions(g::Group) = [p[1] for p in g.positions]
ypositions(g::Group) = [p[2] for p in g.positions]

function leftinkbound(g::Group)
    lefts = leftinkbound.(g.elements) .* g.scales .+ xpositions(g)
    return minimum(lefts)
end

function rightinkbound(g::Group)
    rights = rightinkbound.(g.elements) .* g.scales .+ xpositions(g)
    return maximum(rights)
end

function bottominkbound(g::Group)
    bottoms = -yoffset.(g.elements) .+ bottominkbound.(g.elements) .* g.scales .+ ypositions(g)
    return minimum(bottoms)
end

function topinkbound(g::Group)
    tops = -yoffset.(g.elements) .+ topinkbound.(g.elements) .* g.scales .+ ypositions(g)
    return maximum(tops)
end

struct Space
    width
end

advance(s::Space) = s.width
ascender(s::Space) = 0
yoffset(::Space) = 0

advance(char::TeXChar) = hadvance(get_extent(char.font, char.char))
ascender(char::TeXChar) = ascender(char.font)
yoffset(char::TeXChar) = descender(char.font)

for inkfunc in (:leftinkbound, :rightinkbound, :bottominkbound, :topinkbound)
    @eval $inkfunc(::Space) = 0
    @eval $inkfunc(char::TeXChar) = $inkfunc(get_extent(char.font, char.char))
end

hmid(x) = 0.5*(leftinkbound(x) + rightinkbound(x))
vmid(x) = 0.5*(bottominkbound(x) + topinkbound(x))
inkwidth(x) = rightinkbound(x) - leftinkbound(x)
inkheight(x) = topinkbound(x) - bottominkbound(x)

tex_layout(char::TeXChar) = char
tex_layout(::Nothing) = Space(0)

function tex_layout(integer::Integer, fontenv=DefaultFontEnv)
    elements = TeXChar.(collect(string(integer)), fontenv.number_font)
    return horizontal_layout(elements)
end

function tex_layout(char::Char, fontenv=DefaultFontEnv)
    # TODO Do this better and not hard coded
    # TODO better fontenv interface
    if char in raw".;:!?()[]"
        TeXChar(char, NewCMRegularFont)
    else
        TeXChar(char, fontenv.math_font)
    end
end

# I don't see a reason to go through the Box, HList, VList business
# Let's see if I'll regret it ;)
function tex_layout(expr, fontenv=DefaultFontEnv)
    head = expr.head
    args = [expr.args...]
    n = length(args)
    shrink = 0.6

    if head == :group
        elements = tex_layout.(args, Ref(DefaultFontEnv))
        return horizontal_layout(elements)
    elseif head == :decorated
        core, sub, super = tex_layout.(args)

        core_width = advance(core)
        sub_width = advance(sub) * shrink
        super_width = advance(super) * shrink

        y0 = yoffset(core)

        # TODO Make that not hacky as hell
        # Compute at which height to put superscript
        h = inkheight(TeXChar('u', NewCMItalicFont))

        ysub = y0 + yoffset(sub) * shrink

        return Group(
            [core, sub, super],
            [Point2f0(0, y0), Point2f0(core_width, ysub), Point2f0(core_width, h-0.2)],
            [1, shrink, shrink])
    elseif head == :integral
        # TODO
    elseif head == :underover
        # TODO padding used is arbitrary
        pad = 0.2
        core, sub, super = tex_layout.(args)

        mid = hmid(core)
        dxsub = mid - hmid(sub) * shrink
        dxsuper = mid - hmid(super) * shrink

        # The leftmost element must have x = 0
        x0 = -min(0, dxsub, dxsuper)
        y0 = yoffset(core)

        return Group(
            [core, sub, super],
            [
                Point2f0(x0, y0),
                Point2f0(
                    x0 + dxsub,
                    y0 + bottominkbound(core) - ascender(sub) * shrink),
                Point2f0(
                    x0 + dxsuper,
                    y0 + topinkbound(core) + pad)
            ],
            [1, shrink, shrink]
        )
    elseif head == :function
        name = args[1]
        elements = TeXChar.(collect(name), fontenv.function_font)
        return horizontal_layout(elements)
    elseif head == :space
        return Space(args[1])
    elseif head == :spaced_symbol # TODO add :symbol head to the symbol when needed
        sym = TeXChar(args[1].args[1], fontenv.function_font)
        return horizontal_layout([Space(0.2), sym, Space(0.2)])
    elseif head == :delimited
        grow = 1.1
        elements = tex_layout.(args)
        left, content, right = elements

        height = inkheight(content)
        left_scale = max(1, height / inkheight(left))
        right_scale = max(1, height / inkheight(right))
        scales = [left_scale, 1, right_scale]

        ys = yoffset.(elements)
        @show ys
        y0 = ys[2]
            
        dxs = advance.(elements) .* scales
        xs = [0, cumsum(dxs[1:end-1])...]
        @show bottominkbound(content)
        # TODO Height calculation for the parenthesis looks wrong
        # TODO Check what the algorithm should be there
        # Center the delimiters in the middle of the bot and top baselines ?
        return Group(elements, [
            Point2f0(xs[1], yoffset(left) - bottominkbound(left) + bottominkbound(content)),
            Point2f0(xs[2], y0),
            Point2f0(xs[3], yoffset(right) - bottominkbound(right) + bottominkbound(content))
        ], scales)
    elseif head == :accent || head == :wide_accent
        # TODO
    elseif head == :font
        # TODO
    elseif head == :frac
        # TODO
    elseif head == :symbol
        return TeXChar(args[1], NewCMMathFont)
    end

    @eroro "Unsupported $expr"
end

function horizontal_layout(elements ; scales=ones(length(elements)))
    dxs = advance.(elements)
    ys = yoffset.(elements)
    xs = [0, cumsum(dxs[1:end-1])...]

    return Group(elements, Point2f0.(xs, ys), scales)
end

function unravel(group::Group, parent_pos=Point2f0(0), parent_scale=1.0f0)
    positions = [parent_pos .+ pos for pos in parent_scale .* group.positions]
    scales = group.scales .* parent_scale
    elements = []

    for (elem, pos, scale) in zip(group.elements, positions, scales)
        push!(elements, unravel(elem, pos, scale)...)
    end

    return elements
end

unravel(char, pos, scale) = [(char, pos, scale)]


function draw_glyph!(scene, texchar::TeXChar, position, scale)
    size = 64
    x = position[1] * size
    y = position[2] * size
    text!(scene, string(texchar.char), font=texchar.font, position=position.*size, textsize=size*scale)
end

draw_glyph!(scene, space::Space, position, scale) = nothing


begin  # Quick test
    using CairoMakie
    
    scene = Scene()
    tex = raw"∫ \cos(\omega t) = \lim_{x →\infty} A^j v_{(a + b)}^i \Lambda_L \sum^j_m \sum_{k=1234}^n 22k  \nabla x!"
    expr = parse(TeXExpr, tex)
    layout = tex_layout(expr)

    for (elem, pos, scale) in unravel(layout)
        draw_glyph!(scene, elem, pos, scale)
    end
    scene
end

save("supersub.pdf", scene)

