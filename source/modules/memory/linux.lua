local ffi = require("ffi")
local log = require("log")

local format = string.format
local sub = string.sub

local cast = ffi.cast
local cdef = ffi.cdef
local load = ffi.load
local metatype = ffi.metatype
local new = ffi.new
local typeof = ffi.typeof
local sizeof = ffi.sizeof
local string = ffi.string
local errno = ffi.errno

local lshift = bit.lshift
local rshift = bit.rshift
local bswap = bit.bswap
local band = bit.band
local bor = bit.bor

local libc = ffi.C
local libcap = load("cap")

cdef [[
char *strerror(int errnum);

typedef signed int pid_t;

typedef struct {
	pid_t pid;
	unsigned __int64  dolphin_base_addr;
	unsigned __int64  dolphin_addr_size;
} MEMORY_STRUCT;

typedef struct {
	void *iov_base;	/* pointer to start of buffer */
	size_t iov_len;	/* size of buffer in bytes */
} iovec;

int process_vm_readv(pid_t pid,
						 iovec *local_iov,
						 unsigned long liovcnt,
						 iovec *remote_iov,
						 unsigned long riovcnt,
						 unsigned long flags);

int process_vm_writev(pid_t pid,
						  iovec *local_iov,
						  unsigned long liovcnt,
						  iovec *remote_iov,
						  unsigned long riovcnt,
						  unsigned long flags);

typedef unsigned short ino_t; 	   /* i-node number */
typedef unsigned long  off_t;	   /* offset within a file */

typedef struct {
	ino_t          d_ino;       /* Inode number */
	off_t          d_off;       /* Not an offset; see below */
	unsigned short d_reclen;    /* Length of this record */
	unsigned char  d_type;      /* Type of file; not supported
								  by all filesystem types */
	char           name[256];   /* Null-terminated filename */
} dirent;
typedef struct __dirstream DIR;

int access(const char *path, int amode);
DIR *opendir(const char *name);
int closedir(DIR *dirp);
dirent *readdir(DIR *dirp);

typedef enum {
    CAP_EFFECTIVE=0,                      /* Specifies the effective flag */
    CAP_PERMITTED=1,                      /* Specifies the permitted flag */
    CAP_INHERITABLE=2                     /* Specifies the inheritable flag */
} cap_flag_t;

typedef enum {
    CAP_CLEAR=0,                            /* The flag is cleared/disabled */
    CAP_SET=1                               /* The flag is set/enabled */
} cap_flag_value_t;

typedef void* cap_t;
typedef int cap_value_t;

cap_t cap_get_proc(void);
int cap_free(void *);
int cap_set_proc(cap_t cap_p);
int cap_set_flag(cap_t, cap_flag_t, int, const cap_value_t *, cap_flag_value_t);
]]

local CAP_SYS_PTRACE = 19

local MEMORY = {}
MEMORY.__index = MEMORY
MEMORY.init = metatype("MEMORY_STRUCT", MEMORY)

function MEMORY:hasPermissions()
	local cap = libcap.cap_get_proc()

	if cap == nil then
		return false
	end

	local flag =  new("cap_value_t[1]")
	flag[0] = CAP_SYS_PTRACE

	if libcap.cap_set_flag(cap, libcap.CAP_EFFECTIVE, 1, flag, libcap.CAP_SET) == -1 then
		libcap.cap_free(cap)
		return false
	end

	if libcap.cap_set_proc(cap) ~= 0 then
		libcap.cap_free(cap)
		return false
	end

	libcap.cap_free(cap)
	return true
end


local valid_process_names = {
	["AppRun"] = true,
	["dolphin-emu"] = true,
	["dolphin-emu-qt2"] = true,
	["dolphin-emu-wx"] = true,
}

function MEMORY:findprocess()
	if self:hasProcess() then return false end

	local dir = libc.opendir("/proc/")

	if dir == nil then
		local message = string(libc.strerror(errno()))
		error("error opening directory /proc/: " .. message)
	else
		local entry
		while true do
			entry = libc.readdir(dir)
			if entry == nil then break end -- end of list
			local pid = string(entry.name)
			local f = io.open("/proc/" .. pid .. "/comm")
			if f then
				local line = f:read("*line")
				if valid_process_names[line] then
					self.pid = tonumber(pid)
					log.debug("Found dolphin-emu process: /proc/%d", self.pid)
				end
				f:close()
			end
		end
		libc.closedir(dir)
	end

	return self:hasProcess()
end

function MEMORY:isProcessActive()
	if self.pid ~= 0 then
		return libc.access("/proc/" .. self.pid, 0) == 0
	end
	return false
end

function MEMORY:hasProcess()
	return self.pid ~= 0
end

function MEMORY:clearGamecubeRAMOffset()
	self.dolphin_base_addr = 0
end

function MEMORY:hasGamecubeRAMOffset()
	return self.dolphin_base_addr ~= 0
end

function MEMORY:getGamecubeRAMOffset()
	return tonumber(self.dolphin_base_addr)
end

function MEMORY:getGamecubeRAMSize()
	return tonumber(self.dolphin_addr_size)
end

function MEMORY:close()
	if self:hasProcess() then
		self.pid = 0
		self.dolphin_base_addr = 0
	end
end

function MEMORY:__gc()
	self:close()
end

function MEMORY:findGamecubeRAMOffset()
	if self:hasProcess() then
		love.timer.sleep(0.25) -- Newer versions of dolphin seem to need a bit of time to allocate the memory addresses
		local f = io.open("/proc/" .. self.pid .. "/maps")
		if f then
			--log.debug("Searching /proc/%d/maps for gamecube address space", self.pid)
			local line
			while true do
				line = f:read("*line")
				if not line then break end -- EOF
				if #line > 74 then
					if sub(line, 74, 74 + 18) == "/dev/shm/dolphinmem" or sub(line, 74, 74 + 19) == "/dev/shm/dolphin-emu" then
						local startAddr, endAddr = line:match("^(%x-)%-(%x-)%s")
						if startAddr and endAddr then
							-- Convert hex values to number
							startAddr = tonumber(startAddr, 16)
							endAddr = tonumber(endAddr, 16)
							if (endAddr - startAddr) >= 0x2000000 then
								self.dolphin_base_addr = startAddr
								self.dolphin_addr_size = endAddr - startAddr
								f:close()
								return true
							end
						end
					end
				end
			end
			f:close()
		end
	end

	return false
end

local function read(mem, addr, output, size)
	local localvec = new("iovec[1]")
	local remotevec = new("iovec[1]")

	local ramaddr = mem.dolphin_base_addr + (addr % 0x80000000)	

	localvec[0].iov_base = output
	localvec[0].iov_len = size

	remotevec[0].iov_base = cast("void*", ramaddr)
	remotevec[0].iov_len = size

	local read = libc.process_vm_readv(mem.pid, localvec, 1, remotevec, 1, 0)

	if read == size then
		return true
	else
		log.warn("Failed reading process memory..")
		mem:close()
		return false
	end
end

function MEMORY:readByte(addr)
	if not self:hasProcess() then return 0 end
	local output = new("int8_t[1]")
	read(self, addr, output, sizeof(output))
	return output[0]
end

function MEMORY:readBool(addr)
	return self:readByte(addr) == 1
end

function MEMORY:readUByte(addr)
	if not self:hasProcess() then return 0 end
	local output = new("uint8_t[1]")
	read(self, addr, output, sizeof(output))
	return output[0]
end

local function bswap16(n)
	return bor(rshift(n, 8), lshift(band(n, 0xFF), 8))
end

function MEMORY:readShort(addr)
	if not self:hasProcess() then return 0 end
	local output = new("int16_t[1]")
	read(self, addr, output, sizeof(output))
	return bswap16(output[0])
end

function MEMORY:readUShort(addr)
	if not self:hasProcess() then return 0 end
	local output = new("uint16_t[1]")
	read(self, addr, output, sizeof(output))
	return bswap16(output[0])
end

local flatconversion = ffi.new("union { uint32_t i; float f; }")

function MEMORY:readFloat(addr)
	if not self:hasProcess() then return 0 end
	local output = new("uint32_t[1]")
	read(self, addr, output, sizeof(output))
	flatconversion.i = bswap(output[0])
	return flatconversion.f
end

function MEMORY:readInt(addr)
	if not self:hasProcess() then return 0 end
	local output = new("int32_t[1]")
	read(self, addr, output, sizeof(output))
	return bswap(output[0])
end

function MEMORY:readUInt(addr)
	if not self:hasProcess() then return 0 end
	local output = new("uint32_t[1]")
	read(self, addr, output, sizeof(output))
	return bswap(output[0])
end

function MEMORY:read(addr, len)
	if not self:hasProcess() then return "" end
	local output = new("unsigned char[?]", len)
	read(self, addr, output, sizeof(output))
	return string(output, sizeof(output))
end

return MEMORY