#!/usr/bin/env texlua
local mypath = string.match(debug.getinfo(1, 'S').source, '@(.*)[/\\][^/\\]+')
if mypath then
  package.path = mypath .. '/?.lua;' .. package.path
end

local pdfe = pdfe or require'pdfe'
local process_stream = require'process_stream'
local text_string_to_utf8 = require'decode'.text_string_to_utf8

local function almost_resolve(t, v, i)
  local id
  while t == 10 do
    id = i
    t, v, i = pdfe.getfromreference(v)
  end
  return id, t, v, i
end

local function get_page(elem)
  local id, t, v, i = almost_resolve(pdfe.getfromdictionary(elem, 'Pg'))
  if not t or t < 2 then return end
  assert(id and t == 8)
  return id
end

local convert_kids

local function convert_mc(ctx, mcid, page, stream_id, stream, owner)
  local stream_data = ctx.streams[stream_id or page]
  if not ctx.streams[stream_id or page] then
    stream_data = process_stream(
      stream or ctx.document.Pages[ctx.pagenos[page]].Contents,
      stream and stream.Resources or ctx.document.Pages[ctx.pagenos[page]].Resources
    )
    ctx.streams[stream_id or page] = stream_data
  end
  return {
    type = 'MCR',
    page = assert(ctx.pagenos[page]),
    stream = stream,
    owner = owner,
    content = stream_data[mcid],
  }
end

local function convert_objr(ctx, obj, page)
  local id, _, obj = assert(almost_resolve(pdfe.getfromdictionary(obj, 'Obj')))
  return {
    type = 'OBJR',
    page = ctx.pagenos[page],--assert(ctx.pagenos[page]), -- TODO: assert(...) once tagpdf is adapted
    ObjId = id,
    Obj = obj,
  }
end

local default_namespace = 'http://iso.org/pdf/ssn'
local owner_prefix = 'http://typesetting.eu/pdf_attribute_owner/'

local dehex = lpeg.Cs(
    (lpeg.R('09', 'af', 'AF') * lpeg.R('09', 'af', 'AF') / function(s) return string.char(tonumber(s, 16)) end)^0
  * (lpeg.R('09', 'af', 'AF') / function(s) return string.char(tonumber(s, 16) * 16) end)^-1
) * -1
local function get_string(t, v, x)
  local _, t, v, x = almost_resolve(t, v, x)
  if not t or t < 2 then return end
  assert(t == 6)
  if x then
    v = assert(dehex:match(v))
  end
  return assert(text_string_to_utf8:match(v))
end

local function pdf2lua(t, v, x)
  local saved = {}
  local function recurse(t, v, x)
    if t == 10 then
      local id
      id, t, v, x = almost_resolve(t, v, x)
      local result = saved[id]
      if result == nil then
        result = recurse(t, v, x)
        saved[id] = result
      end
      return result
    end
    if not t or t < 2 then
      return
    elseif t < 6 then
      return v
    elseif t == 6 then
      return get_string(t, v, x)
    elseif t == 7 then
      local arr = {}
      for i=1, #v do
        arr[i] = pdf2lua(pdfe.getfromarray(v, i))
      end
      return arr
    elseif t == 8 then
      local dict = {}
      for i=1, #v do
        local k, it, iv, ix = pdfe.getfromdictionary(v, i)
        dict[k] = pdf2lua(it, iv, ix)
      end
      return dict
    else
      assert(false, 'Streams are not handled at the moment')
    end
  end
  return recurse(t, v, i)
end

local function convert_attributes(ctx, attrs, classes)
  if not classes and not attrs then return end
  local attributes = {}
  local function apply_attr(attr)
    local owner = assert(attr.O)
    if owner == 'NSO' then
      owner = attr.NS.NS
    else
      owner = owner_prefix .. owner
    end
    local owner_dict = attributes[owner]
    if not owner_dict then
      owner_dict = {}
      attributes[owner] = owner_dict
    end
    for i = 1, #attr do
      local key, t, v, extra = pdfe.getfromdictionary(attr, i)
      if key ~= 'O' and key ~= 'NS' then
        owner_dict[key] = pdf2lua(t, v, extra)
      end
    end
  end
  local function apply_attrs(attrs)
    local t = pdfe.type(attrs)
    if t == 'pdfe.dictionary' then
      apply_attr(attrs)
    else
      assert(t == 'pdfe.array')
      for i=1, #attrs do
        local attr = attrs[i]
        if type(attr) ~= 'number' then
          apply_attr(attr)
        end
      end
    end
  end
  if classes then
    if type(classes) == 'string' then
      apply_attrs(ctx.ClassMap[classes])
    else
      for i=1, #classes do
        local class = classes[i]
        if type(class) ~= 'number' then
          apply_attrs(ctx.ClassMap[classes[i]])
        end
      end
    end
  end
  if attrs then
    apply_attrs(attrs)
  end
  return attributes
end

local function convert(ctx, elem, id, page)
  if type(elem) == 'number' then
    return convert_mc(ctx, elem, page)
  elseif elem.Type == 'MCR' then
    local stm_id, _, stm = almost_resolve(pdfe.getfromdictionary(elem, 'Stm'))
    return convert_mc(ctx, elem.MCID, get_page(elem) or page, stm_id, stm, elem.StmOwn)
  elseif elem.Type == 'OBJR' then
    return convert_objr(ctx, elem, get_page(elem) or page)
  end
  local ns = elem.NS
  local role_mapped_s, role_mapped_ns
  ns = ns and ns.NS or default_namespace
  local obj = {
    subtype = ctx.type_maps[elem.NS and elem.NS.NS or false][elem.S],
    attributes = convert_attributes(ctx, elem.A, elem.C),
    title = get_string(pdfe.getfromdictionary(elem, 'T')),
    lang = get_string(pdfe.getfromdictionary(elem, 'Lang')),
    alt = get_string(pdfe.getfromdictionary(elem, 'Alt')),
    expanded = get_string(pdfe.getfromdictionary(elem, 'E')),
    actual_text = get_string(pdfe.getfromdictionary(elem, 'ActualText')),
    associated_files = elem.AF,
    kids = convert_kids(ctx, elem),
  }
  ctx.id_map[id] = obj
  local elem_ref = elem.Ref
  if elem_ref and #elem_ref > 0 then
    local ref = {}
    for i = 1, #elem_ref do
      ref[i] = assert(almost_resolve(pdfe.getfromarray(elem_ref, i)))
    end
    obj.ref = ref
    ctx.ref_entries[#ctx.ref_entries + 1] = obj
  end
  return obj
end

function convert_kids(ctx, elem)
  local id, t, k = almost_resolve(pdfe.getfromdictionary(elem, 'K'))
  if not k then return nil end
  local page = get_page(elem)
  if t == 7 then
    local result = {}
    for i = 1, #k do
      local id, t, kid = almost_resolve(pdfe.getfromarray(k, i))
      result[i] = convert(ctx, k[i], id, page)
    end
    return result
  else
    return {convert(ctx, k, id, page)}
  end
end

local function open(filename)
  local document = pdfe.open(filename)
  if 0 < pdfe.getstatus(document) then
    return nil, 'Failed to open document'
  end
  local ctx = {
    document = document,
    streams = {},
  }

  local catalog = pdfe.getcatalog(document)
  local markinfo = catalog and catalog.MarkInfo
  local tagged = markinfo and markinfo.Marked

  if not tagged then
    return nil, 'Document is not tagged'
  end

  local pagenos = {}
  for i, page in ipairs(pdfe.pagestotable(document)) do
    pagenos[page[3]] = i
  end
  ctx.pagenos = pagenos

  local id_map = {}
  ctx.id_map = id_map
  ctx.ref_entries = {}

  local structroot = catalog.StructTreeRoot
  if not structroot then
    return {}, ctx
  end
  local type_maps = {}
  do
    local namespaces = structroot.Namespaces
    for i=0, namespaces and #namespaces or 0 do
      local ns, role_map
      if i == 0 then
        ns = false
        role_map = structroot.RoleMap
      else
        local namespace = namespaces[i]
        ns = namespace.NS
        role_map = namespace.RoleMapNS
      end
      type_maps[ns] = setmetatable({}, {__index = function(t, elem)
        local element = {subtype = elem, namespace = ns}
        t[elem] = element

        local mapped = role_map and role_map[elem]
        if type(mapped) == 'string' then
          mapped = {mapped, false}
        end
        if mapped then
          element.mapped = type_maps[mapped[2]][mapped[1]]
        end
        return element
      end})
    end
  end
  ctx.type_maps = type_maps
  ctx.ClassMap = structroot.ClassMap
  local elements = convert_kids(ctx, structroot)
  ctx.ClassMap = nil

  for _, obj in ipairs(ctx.ref_entries) do
    local refs = obj.ref
    for i, ref in ipairs(refs) do
      refs[i] = assert(id_map[ref])
    end
  end
  ctx.ref_entries = nil

  return elements, ctx
end

local function mark_references(tree)
  local count = 0
  local referenced = {}
  local function recurse(objs)
    for _, obj in ipairs(objs) do
      if obj.ref then
        for _, ref in ipairs(obj.ref) do
          if not referenced[ref] then
            count = count + 1
            referenced[ref] = count
          end
        end
      end
      if obj.kids then
        recurse(obj.kids)
      end
    end
  end
  recurse(tree)
  return referenced, count
end

local function format_subtype(subtype)
  if subtype.namespace then
    return string.format('%s (%s)', subtype.subtype, subtype.namespace)
  else
    return subtype.subtype
  end
end
local function print_tree(tree)
  local referenced = mark_references(tree)
  local function recurse(objs, first_prefix, last_first_prefix, prefix, last_prefix)
    for i, obj in ipairs(objs) do
      if i == #objs then first_prefix, prefix = last_first_prefix, last_prefix end
      if obj.type == 'MCR' then
        print(string.format('%sMarked content on page %i: %s', first_prefix, obj.page, obj.content))
      elseif obj.type == 'OBJR' then
        local t = obj.Obj.Type
        t = t and string.format(' of type %s', t) or ''
        local page = obj.page
        page = page and string.format(' on page %i', page) or '' -- TODO: Should eventually become always true
        print(string.format('%sReferenced object%s%s', first_prefix, t, page))
      else
        local mark = obj.kids and ':' or ''
        local subtype = obj.subtype
        local mapped = subtype.mapped
        mapped = mapped and ' / ' .. format_subtype(mapped) or ''
        print(string.format('%s%s%s%s', first_prefix, format_subtype(subtype), mapped, mark))
        local lines = {}
        if referenced[obj] then
          lines[#lines + 1] = 'Referenced as object ' .. referenced[obj]
        end
        if obj.title then
          lines[#lines + 1] = 'Title: ' .. obj.title
        end
        if obj.lang then
          lines[#lines + 1] = 'Language: ' .. obj.lang
        end
        if obj.expanded then
          lines[#lines + 1] = 'Expansion: ' .. obj.expanded
        end
        if obj.alt then
          lines[#lines + 1] = 'Alternate text: ' .. obj.alt
        end
        if obj.actual_text then
          lines[#lines + 1] = 'Actual text: ' .. obj.actual_text
        end
        if obj.associated_files then
          lines[#lines + 1] = 'Associated files are present'
        end
        if obj.attributes then
          local owners = {}
          for k in next, obj.attributes do
            owners[#owners + 1] = k
          end
          table.sort(owners)
          for i=1, #owners do
            local attrs = {}
            for k in next, obj.attributes[owners[i]] do
              attrs[#attrs + 1] = k
            end
            table.sort(attrs)
            for j=1, #attrs do
              attrs[j] = attrs[j] .. ': ' .. require'inspect'(obj.attributes[owners[i]][attrs[j]])
            end
            table.insert(attrs, 1, (owners[i]:sub(1, #owner_prefix) == owner_prefix and '/' .. owners[i]:sub(#owner_prefix+1) or  owners[i]) .. ':')
            for j=1, #attrs-1 do
              attrs[j] = attrs[j]:gsub('\n', '\n│')
            end
            owners[i] = table.concat(attrs, '\n├', 1, #attrs-1) .. '\n└' .. attrs[#attrs]:gsub('\n', '\n ')
          end
          table.insert(owners, 1, 'Attributes: ')
          for j=1, #owners-1 do
            owners[j] = owners[j]:gsub('\n', '\n│')
          end
          lines[#lines + 1] = table.concat(owners, '\n├', 1, #owners-1) .. '\n└' .. owners[#owners]:gsub('\n', '\n ')
        end
        -- attributes = convert_attributes(elem.A),
        -- attribute_classes = convert_attribute_classes(elem.C),
        if obj.ref then
          local refs = {}
          for i, r in ipairs(obj.ref) do
            refs[i] = referenced[r]
          end
          lines[#lines + 1] = 'References object' .. (refs[2] and 's' or '') .. ' ' .. table.concat(refs, ', ')
        end
        if obj.kids then
          for _, l in ipairs(lines) do
            print(prefix .. '┝━━' .. l:gsub('\n', '\n' .. prefix .. '│  '))
          end
          recurse(obj.kids, prefix .. '├─', prefix .. '└─', prefix .. '│ ', prefix .. '  ')
        elseif #lines > 0 then
          for i=1, #lines-1 do
            print(prefix .. '┝━━' .. lines[i]:gsub('\n', '\n' .. prefix .. '│  '))
          end
          print(prefix .. '┕━━' .. lines[#lines]:gsub('\n', '\n' .. prefix .. '   '))
        end
      end
    end
  end
  return recurse(tree, '', '', '', '')
end

if not arg[1] then
  io.stderr:write(string.format('Missing argument. Usage: %s <filename>.pdf\n', arg[0]))
  return
end

local struct, ctx = assert(open(arg[1]))
print_tree(struct, '')
-- print(require'inspect'(struct))
