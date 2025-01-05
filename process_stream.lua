local lpeg = lpeg or require'lpeg'
local pdfscanner = require'luapdfscanner'
local utf16be_to_utf8 = require'decode'.utf16be_to_utf8
local text_string_to_utf8 = require'decode'.text_string_to_utf8

local lookup = {}

local cmap_operators = {
  beginbfrange = function(scanner, ctx)
    assert(not ctx.mode)
    ctx.mode = 'bfrange'
    ctx.count = scanner:popnumber()
  end,
  endbfrange = function(scanner, ctx)
    assert(ctx.mode == 'bfrange')
    ctx.mode = nil
    for i=1, ctx.count do
      local target = scanner:popstring() or scanner:poparray()
      local last = scanner:popstring()
      local first = scanner:popstring()
      if first:sub(1, -2) == last:sub(1, -2) then
        if type(target) == 'string' then
          local in_prefix = first:sub(1, -2)
          ctx.pattern = ctx.pattern + in_prefix * lpeg.R(first:sub(-1) .. last:sub(-1))
          local out_prefix = target:sub(1, -2)
          local in_suffix = first:byte(-1)
          local out_suffix = target:byte(-1)
          for i = 0, last:byte(-1) - in_suffix do
            ctx.mapping[in_prefix .. string.char(in_suffix + i)] = out_prefix .. string.char(out_suffix + i)
          end
        else
          print(require'inspect'{first, last, target, 'bfrange'})
          error'TODO'
        end
      else
        io.stderr:write("WARNING: Ignoring invalid ToUnicode mapping\n")
      end
    end
  end,
  beginbfchar = function(scanner, ctx)
    assert(not ctx.mode)
    ctx.mode = 'bfchar'
    ctx.count = scanner:popnumber()
  end,
  endbfchar = function(scanner, ctx)
    assert(ctx.mode == 'bfchar')
    ctx.mode = nil
    for i=1, ctx.count do
      local mapped = scanner:popstring()
      local char = scanner:popstring()
      ctx.mapping[char] = mapped
      ctx.pattern = ctx.pattern + char
    end
  end,
  endcmap = function(scanner, ctx)
    scanner:done()
  end,
}

local function parse_cmap(stream)
  local ctx = {
    pattern = lpeg.P(false), -- Maybe use 1 instead to passthough everything else
    mapping = {},
  }
  pdfscanner.scan(stream, cmap_operators, ctx)
  return lpeg.Cs((ctx.pattern/ctx.mapping)^0) * -1
end

local function print_string(ctx, str, pattern)
  if pattern then
    str = pattern:match(str)
  end
  if not pattern or not str then
    str = '\xff\xfd'
  end
  str = assert(utf16be_to_utf8:match(str))
  ctx.text_buffer[#ctx.text_buffer + 1] = str
end

local operators = {
  BT = function(scanner, ctx)
    assert(not ctx.text_mode)
    ctx.text_mode = true
  end,
  ET = function(scanner, ctx)
    assert(ctx.text_mode)
    ctx.text_mode = false
  end,
  Tf = function(scanner, ctx)
    assert(ctx.fonts)
    local size = scanner:popnumber()
    local name = scanner:popname()
    local font_type, font_ref, font_id = pdfe.getfromdictionary(ctx.fonts, name)
    assert(font_type == 10)
    local font_type, font = pdfe.getfromreference(font_ref)
    ctx.current_font = {
      id = font_id,
      obj = font,
      cmap = font.ToUnicode and parse_cmap(font.ToUnicode),
    }
  end,
  Tj = function(scanner, ctx)
    if not ctx.text_buffer then return end
    local font = ctx.current_font
    assert(ctx.text_mode and font)
    local pattern = font.cmap
    local text = scanner:popstring()
    print_string(ctx, text, pattern)
  end,
  TJ = function(scanner, ctx)
    if not ctx.text_buffer then return end
    local font = ctx.current_font
    assert(ctx.text_mode and font)
    local pattern = font.cmap
    local texts = scanner:poparray()
    for _, entry in ipairs(texts) do
      if entry[1] == 'string' then
        print_string(ctx, entry[2], pattern)
      end
    end
  end,
  BMC = function(scanner, ctx)
    local tag = scanner:popname()
    local stack = ctx.marked_stack
    local top = {
      tag = tag,
    }
    stack[#stack + 1] = top
    if tag == 'Artifact' then
      top.artifact = ctx.artifact
      ctx.artifact = true
    end
  end,
  BDC = function(scanner, ctx)
    local props = assert(scanner:popdictionary() or ctx.properties and ctx.properties[scanner:popname()])
    local tag = scanner:popname()
    local stack = ctx.marked_stack
    local top = {
      tag = tag,
      props = props,
    }
    stack[#stack + 1] = top
    if props.ActualText or props.MCID then
      top.text_buffer = ctx.text_buffer
      ctx.text_buffer = not props.ActualText and {}
    end
    if tag == 'Artifact' then
      top.artifact = ctx.artifact
      ctx.artifact = true
    end
  end,
  EMC = function(scanner, ctx)
    local stack = ctx.marked_stack
    local top = assert(stack[#stack])
    stack[#stack] = nil
    local tag = top.tag
    top.tag = nil
    local props = top.props
    if props then
      top.props = nil
      local text
      local outer_text_buffer = top.text_buffer
      if props.ActualText and (props.MCID or outer_text_buffer) then
        text = type(props) == 'table' and props.ActualText[2] or props.ActualText
        text = text_string_to_utf8:match(text)
      end
      if props.MCID then
        text = text or table.concat(ctx.text_buffer)
        local MCID = type(props) == 'table' and props.MCID[2] or props.MCID
        ctx.marked_content_elements[MCID] = text
      end
      if text and outer_text_buffer then
        outer_text_buffer[#outer_text_buffer + 1] = text
      end
    end
    for k, v in next, top do
      ctx[k] = v
    end
  end,
}
operators['"'] = operators.Tj
operators["'"] = operators.Tj

return function(stream, resources)
  local fonts = resources and resources.Font
  local ctx = {
    fonts = resources and resources.Font,
    properties = resources and resources.Properties,
    text_mode = false,
    marked_stack = {},
    artifact = false,
    text_buffer = false,
    -- current_font = nil,
    marked_content_elements = {},
  }
  if pdfe.type(stream) == 'pdfe.array' then
    local arr = {}
    for i=1, #stream do
      arr[i] = stream[i]
    end
    stream = arr
  end
  pdfscanner.scan(stream, operators, ctx)
  return ctx.marked_content_elements
end
