"""The one reader of 32-bit PE files in this repo: sections, relocations, imports and exports."""
import bisect
import functools
import struct

FLAT_BASE = 0x62000000              # where a flat binary (the synthetic tests) is taken to be linked

DOS_SIGNATURE = b'MZ'
PE_SIGNATURE = b'PE\0\0'
PE32_MAGIC = 0x10b                  # the optional header of a 32-bit image
SECTION_EXECUTABLE = 0x20000000
RELOCATION_HIGHLOW = 3              # a relocation that adds the load address to a 32-bit field
DIRECTORY_EXPORT, DIRECTORY_IMPORT, DIRECTORY_RELOCATION = 0, 1, 5


class Fail(Exception):
    """Something a tool cannot work with: an unexpected file, an address outside the image, a routine the
    translator refuses."""


class Image:
    """A PE file (mode 'pe', addresses are RVAs) or a flat binary (mode 'flat', addresses are offsets)."""

    def __init__(self, path, mode='pe'):
        with open(path, 'rb') as file:
            self.data = file.read()
        self.path = path
        if mode == 'pe':
            self.header = self.pe_header()
            optional = self.header + 24
            section_count = struct.unpack_from('<H', self.data, self.header + 6)[0]
            optional_size = struct.unpack_from('<H', self.data, self.header + 20)[0]
            self.base = struct.unpack_from('<I', self.data, optional + 28)[0]
            self.size = struct.unpack_from('<I', self.data, optional + 56)[0]
            self.directories = optional + 96
            first = optional + optional_size
            # (virtual size, virtual address, raw size, file offset) of every section
            self.sections = [struct.unpack_from('<IIII', self.data, first + 40 * k + 8) for k in range(section_count)]
            self.text = [(va, va + vs) for k, (vs, va, _rs, _raw) in enumerate(self.sections)
                         if struct.unpack_from('<I', self.data, first + 40 * k + 36)[0] & SECTION_EXECUTABLE]
        else:
            self.header = None
            self.base = FLAT_BASE
            self.size = len(self.data)
            self.sections = [(len(self.data), 0, len(self.data), 0)]
            self.text = [(0, len(self.data))]

    def pe_header(self):
        """File offset of the PE header, after a check that this is a 32-bit PE file."""
        data = self.data
        if len(data) >= 0x40 and data[:2] == DOS_SIGNATURE:
            header = struct.unpack_from('<I', data, 0x3c)[0]
            if header + 26 <= len(data) and data[header:header + 4] == PE_SIGNATURE \
                    and struct.unpack_from('<H', data, header + 24)[0] == PE32_MAGIC:
                return header
        raise Fail('%s is not a 32-bit PE file' % self.path)

    def directory(self, index):
        """(rva, size) of a data directory, (0, 0) for a flat binary."""
        if self.header is None:
            return (0, 0)
        return struct.unpack_from('<II', self.data, self.directories + 8 * index)

    def offset_of(self, rva):
        """File offset of an address of the image."""
        for vs, va, rs, raw in self.sections:
            if va <= rva < va + max(vs, rs):
                return raw + rva - va
        raise Fail('rva %x not in image' % rva)

    def bytes(self, s, e):
        return self.data[self.offset_of(s):self.offset_of(s) + (e - s)]

    def dword(self, rva):
        return struct.unpack_from('<I', self.data, self.offset_of(rva))[0]

    def name_at(self, rva):
        start = self.offset_of(rva)
        return self.data[start:self.data.index(b'\0', start)].decode()

    @functools.cached_property
    def relocs(self):
        """RVAs of the 32-bit fields the loader adds the load address to."""
        relocs = set()
        rva, size = self.directory(DIRECTORY_RELOCATION)
        if not rva:
            return relocs
        position = self.offset_of(rva)
        end = position + size
        while position < end:
            page, block = struct.unpack_from('<II', self.data, position)
            if block < 8:
                break
            for k in range((block - 8) // 2):
                entry = struct.unpack_from('<H', self.data, position + 8 + 2 * k)[0]
                if entry >> 12 == RELOCATION_HIGHLOW:
                    relocs.add(page + (entry & 0xfff))
            position += block
        return relocs

    @functools.cached_property
    def relocs_sorted(self):
        return sorted(self.relocs)

    def relocs_in(self, s, e):
        a = bisect.bisect_left(self.relocs_sorted, s)
        b = bisect.bisect_left(self.relocs_sorted, e)
        return self.relocs_sorted[a:b]

    @functools.cached_property
    def pointers(self):
        """Sorted (value rva, location rva) of every relocated pointer, to find who points where."""
        pointers = []
        for location in self.relocs_sorted:
            try:
                pointers.append((self.dword(location) - self.base, location))
            except Fail:
                pass                # a relocation outside every section holds no pointer of the file
        pointers.sort()
        return pointers

    @functools.cached_property
    def imports(self):
        """Import address table slot rva -> (dll in lower case, function name), for imports by name."""
        imports = {}
        rva, _size = self.directory(DIRECTORY_IMPORT)
        position = self.offset_of(rva) if rva else None
        while position is not None:
            lookup, _, _, name, slots = struct.unpack_from('<5I', self.data, position)
            if not name:
                break
            dll = self.name_at(name).lower()
            k = 0
            while True:
                thunk = self.dword((lookup or slots) + 4 * k)
                if not thunk:
                    break
                if not thunk & 0x80000000:
                    imports[slots + 4 * k] = (dll, self.name_at(thunk + 2))
                k += 1
            position += 20
        return imports

    def exports(self):
        """(RVAs of all exported functions, sorted (rva, name) of those exported by name)."""
        rva, _size = self.directory(DIRECTORY_EXPORT)
        if not rva:
            return (), []
        function_count, name_count, functions_at, names_at, ordinals_at = struct.unpack_from('<5I', self.data, self.offset_of(rva) + 20)
        functions = struct.unpack_from('<%dI' % function_count, self.data, self.offset_of(functions_at)) if function_count else ()
        if not name_count:
            return functions, []
        names = struct.unpack_from('<%dI' % name_count, self.data, self.offset_of(names_at))
        ordinals = struct.unpack_from('<%dH' % name_count, self.data, self.offset_of(ordinals_at))
        return functions, sorted((functions[ordinals[k]], self.name_at(names[k])) for k in range(name_count))
