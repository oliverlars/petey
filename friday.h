#define __asm(x)
#define __attribute__(x)

#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>


#define FRIDAY_VERSION "IV"

/*
Thanks to
- shachaf
- graphitemaster

For giving me a hand with the synchronisation barrier on mac
*/

typedef signed char s8;
typedef signed short int s16;
typedef signed int s32;
typedef signed long long s64;
typedef unsigned char u8;
typedef unsigned short int u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef float f32;
typedef double f64;
typedef unsigned char b8;
typedef unsigned short int b16;
typedef unsigned int b32;
typedef unsigned long long b64;

#define KiloBytes(X) (1024ll * X)
#define MegaBytes(X) (1024ll * KiloBytes(X))
#define GigaBytes(X) (1024ll * MegaBytes(X))

size_t strlen(const char *str);

#define Min(a, b) ((a) < (b) ? (a) : (b))

#define Str8ToPrintfArgs(String) (int)String.Size, (char*)String.Bytes
#define Str8(String) (str8) { strlen(String), (s8*)String }

#define ArenaPushType(Arena, Type) (Type *)ArenaPush(Arena, sizeof(Type))

struct shared_wave_info;
struct wave_info;

u8 *SharedArenaPush(struct wave_info *WaveInfo, s64 Bytes);

#define False 0
#define True (!False)
#define Null (void *)0

#define STR_COLOUR_RED     "\x1B[31m"
#define STR_COLOUR_GREEN   "\x1B[32m"
#define STR_COLOUR_YELLOW  "\x1B[33m"
#define STR_COLOUR_BLUE    "\x1B[34m"
#define STR_COLOUR_MAGENTA "\x1B[35m"
#define STR_COLOUR_CYAN    "\x1B[36m"
#define STR_COLOUR_WHITE   "\x1B[37m"
#define STR_COLOUR_RESET   "\x1B[0m"

typedef enum operating_system
{
	OS_WINDOWS,
	OS_DARWIN,
	OS_LINUX,
}
operating_system;

typedef struct memory_arena
{
	u8 *Start;
	s64 Committed;
	s64 At;
} memory_arena;

typedef struct str8
{
	s64 Size;
	s8 *Bytes;
} str8;

typedef struct str8_list_node
{
	struct str8_list_node *Next;
	struct str8_list_node *Previous;
	str8 String;
} str8_list_node;

typedef struct str8_list
{
	str8_list_node *First;
	str8_list_node *Last;
} str8_list;

#define array(T) struct { T *Items; s64 Count; }

typedef array(str8) str8_array;

#if defined(__APPLE__)

#include <util.h>
typedef enum compiler
{
	COMPILER_PLATFORM_DEFAULT = 0,
	COMPILER_CLANG = 0,
	COMPILER_GCC = 1,

	COMPILER_MSVC = COMPILER_PLATFORM_DEFAULT,

	COMPILER_COUNT,
} compiler;
#elif defined(_WIN32)
#include <stdatomic.h>

typedef enum compiler
{
	COMPILER_PLATFORM_DEFAULT = 0,
	COMPILER_MSVC = 0,
	COMPILER_CLANG = 1,

	COMPILER_GCC = COMPILER_PLATFORM_DEFAULT,
	COMPILER_COUNT,
} compiler;
#endif

typedef enum diagnostic_type
{
	D_WARNING,
	D_F_ERROR,
	D_INFO,
}
diagnostic_type;

typedef struct diagnostic
{
	diagnostic_type Type;
	str8 Message;
	struct diagnostic *Next;
}
diagnostic;


typedef struct diagnostic_info
{
	diagnostic *Diagnostics;
}
diagnostic_info;

typedef enum output_type
{
	OUTPUT_EXECUTABLE,
	OUTPUT_STATIC_LIBRARY,
	OUTPUT_DYNAMIC_LIBRARY,
	OUTPUT_COUNT,
} output_type;

typedef struct build_options
{
	compiler Compiler;

	output_type OutputType;
	str8 OutputName;
	str8 OutputPath;

	str8 WorkingDirectory;

	str8_list IncludePaths;
	str8_list SourceFiles;
	str8_list ExtraLinkFlags;
	str8_list ExtraCompileFlags;

	b32 Optimise;
	b32 FullRebuild;
	b32 GenerateDebugInfo;
	b32 PrintHelpMenu;
} build_options;


u8* ArenaPush(memory_arena *Arena, s64 Bytes);
u8 *ArenaPush(memory_arena *Arena, s64 Bytes);
str8 Str8PushF(memory_arena *Arena, char *Format, ...);
str8 Str8ListJoin(memory_arena *Arena, str8_list List);
str8 Str8ArrayJoin(memory_arena *Arena, str8_array Array);
void Str8ListAppend(memory_arena *Arena, str8_list *List, str8 String);
b32  Str8EndsWith(str8 String, str8 EndsWith);
char *CStrFromStr8(memory_arena *Arena, str8 String);
str8_list ListOfDirectoryEntriesFromPath(memory_arena *Arena, str8 Path);


#define F_ERROR STR_COLOUR_WHITE "[" STR_COLOUR_RED "F_ERROR" STR_COLOUR_WHITE "]\n" STR_COLOUR_RESET
#define F_WARN STR_COLOUR_WHITE "[" STR_COLOUR_YELLOW "SUCCESS" STR_COLOUR_YELLOW "]\n" STR_COLOUR_RESET
#define F_SUCCESS STR_COLOUR_WHITE "[" STR_COLOUR_GREEN "SUCCESS" STR_COLOUR_WHITE "]\n" STR_COLOUR_RESET

void GobbleWhitespace(str8 File, u64 *At);
void GobbleUpToWhitespace(str8 File, u64 *At);

operating_system GetOperatingSystem();



#if __APPLE__
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/types.h>
#include <dirent.h>
#include <stdatomic.h>
#include <spawn.h>
#include <sys/wait.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <mach/mach_time.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <os/os_sync_wait_on_address.h>
#include <os/lock.h>

extern char **environ;

#define MemoryReserve(NumberOfBytes) (u8 *)mmap(NULL, NumberOfBytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
#define MemoryCommit(Address, NumberOfBytes) mprotect(Address, NumberOfBytes, PROT_READ|PROT_WRITE)

#define MemoryCopy(Destination, Source, NumberOfBytes) memcpy(Destination, Source, NumberOfBytes)
#define MemoryZero(Destination, NumberOfBytes) memset(Destination, 0, NumberOfBytes)

#define thread_local _Thread_Local

operating_system GetOperatingSystem()
{
	return OS_DARWIN;
}

u64 GetPageSize()
{
	return getpagesize();
}

str8 LoadEntireFileIntoMemory(memory_arena *Arena, str8 Filename)
{
	s32 FileHandle = open(CStrFromStr8(Arena, Filename), O_RDONLY);
	if (FileHandle == -1)
	{
		printf("File not found");
		return (str8){0};
	}

	struct stat FileStat;
	fstat(FileHandle, &FileStat);

	u8 *BackingMemory = ArenaPush(Arena, (u64)FileStat.st_size + 1);
	BackingMemory[FileStat.st_size] = 0;

	str8 Result = {0};
	Result.Bytes = (s8*)BackingMemory;
	Result.Size = FileStat.st_size;

	ssize_t BytesRead = read(FileHandle, BackingMemory, FileStat.st_size);

	return Result;
}

void WriteStringToDisk(memory_arena *Arena, str8 DestinationPath, str8 StringToWrite)
{
	s32 FileDescriptor = creat(CStrFromStr8(Arena, DestinationPath), S_IRUSR | S_IWUSR );
	s64 BytesWritten = write(FileDescriptor, StringToWrite.Bytes, StringToWrite.Size);
}

str8 GetExecutableDirectory(memory_arena *Arena)
{
	s32 NumberOfBytes = PATH_MAX;
	u8 *BackingMemory = ArenaPush(Arena, NumberOfBytes);

	getcwd((char*)BackingMemory, PATH_MAX);

	str8 Result = {0};
	Result.Size = NumberOfBytes;
	Result.Bytes = (s8*)BackingMemory;

	return Result;
}

void AppendSourceFilesInFolder(memory_arena *Arena, str8_list *SourceFilesFromFolder, str8 Path)
{
	str8 SourceFilesInDirectory = Str8PushF(Arena, "%.*s/", Str8ToPrintfArgs(Path));

	DIR *Directory = opendir((char*)SourceFilesInDirectory.Bytes);
	struct dirent *Entry;
	if(Directory == Null)
	{ 
		printf("Unknown directory %.*s", Str8ToPrintfArgs(Path));
		return;
	}

	while((Entry = readdir(Directory)))
	{
		if (Entry->d_name[0] != '.' && (Str8EndsWith(Str8(Entry->d_name), Str8(".c")) ||
										Str8EndsWith(Str8(Entry->d_name), Str8(".m"))))
		{
			struct stat FileStat;
			stat(Entry->d_name, &FileStat);
			if (!S_ISDIR(FileStat.st_mode))
			{
				str8 SourceFilepath = Str8PushF(Arena, "%.*s/%s", Str8ToPrintfArgs(Path), Entry->d_name);
				Str8ListAppend(Arena, SourceFilesFromFolder, SourceFilepath);
			}
		}
	}
}

b32 PathExists(memory_arena *Arena, str8 Filename)
{
	return access(CStrFromStr8(Arena, Filename), F_OK) == 0;
}

s64 AtomicAdd(s64 *Value, s64 Addend)
{
	return __sync_fetch_and_add(Value, Addend);
}

u64 TimeStampNow()
{
	return mach_absolute_time();
}

f32 MilliSecondsFromTimeStamp(u64 TimeStamp)
{
	mach_timebase_info_data_t Info;
	mach_timebase_info(&Info);

	return (f32)((TimeStamp) * Info.numer / Info.denom) / 1000000.0;

}

s64 GetNumberOfCPUs()
{
	s32 NumberOfCPUs;
	size_t len = sizeof(NumberOfCPUs);

	sysctlbyname("hw.ncpu", &NumberOfCPUs, &len, NULL, 0);

	return NumberOfCPUs;
}

str8_list ListOfDirectoryEntriesFromPath(memory_arena *Arena, str8 Path)
{
	str8_list Entries = { 0 };
	DIR *Directory = opendir(CStrFromStr8(Arena, Path));
	struct dirent *Entry;
	while((Entry = readdir(Directory)))
	{
		if(Entry->d_name[0] != '.')
		{
			Str8ListAppend(Arena, &Entries, Str8PushF(Arena, "%s", Entry->d_name));
		}
	}
	return Entries;
}

void DeleteFileFromDisk(memory_arena *Arena, str8 Filename)
{
	remove(CStrFromStr8(Arena, Filename));
}

int MoveFileOnDisk(memory_arena *Arena, str8 Source, str8 Destination)
{
	return rename(CStrFromStr8(Arena, Source), CStrFromStr8(Arena, Destination));
}

/*

I don't like how I need spaces at the ends of the commands.
This whole thing is dumb

HACK(Oliver): Fix ExecuteCommand spaces

 */
b32 ExecuteCommand(memory_arena *Arena, str8 EntireCommandAndArguments, b32 *FailedToExecute)
{
	pid_t ProcessID;
	posix_spawn_file_actions_t SpawnActions;

	int MasterFD = -1;
	int SlaveFD = -1;
	openpty(&MasterFD, &SlaveFD, Null, Null, Null);

	posix_spawn_file_actions_init(&SpawnActions);

	posix_spawn_file_actions_adddup2(&SpawnActions, SlaveFD, STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&SpawnActions, SlaveFD, STDERR_FILENO);
	posix_spawn_file_actions_addclose(&SpawnActions, MasterFD);
	posix_spawn_file_actions_addclose(&SpawnActions, SlaveFD);

	char** CompilerArguments = (char**)ArenaPush(Arena, 1024*sizeof(char*));
	u64 ArgumentIndex = 0;
	for(u64 Index = 0; Index < EntireCommandAndArguments.Size; Index++, ArgumentIndex++)
	{
		GobbleWhitespace(EntireCommandAndArguments, &Index);
		u64 IndexUpToWhitespace = Index;
		GobbleUpToWhitespace(EntireCommandAndArguments, &IndexUpToWhitespace);
		str8 Argument = { 0 };
		Argument.Bytes = EntireCommandAndArguments.Bytes + Index;
		Argument.Size = IndexUpToWhitespace - Index;
		CompilerArguments[ArgumentIndex] = CStrFromStr8(Arena, Argument);
		Index += Argument.Size;
	}

	CompilerArguments[ArgumentIndex] = Null;

	s32 ProcessStatus = posix_spawnp(&ProcessID, CompilerArguments[0], &SpawnActions, Null, CompilerArguments, environ);
	posix_spawn_file_actions_destroy(&SpawnActions);
	
	if (ProcessStatus == 0)
	{
		close(SlaveFD);

		str8_list StdOutList = {0};

		s32 ExitCode;
		u8 *BackingMemory = ArenaPush(Arena, 4096);
		s64 NumberOfBytesRead = 0;  
		do
		{
			NumberOfBytesRead = read(MasterFD, BackingMemory, 4096);
			str8 String = {.Bytes = (s8*)BackingMemory, .Size = NumberOfBytesRead};
			write(STDOUT_FILENO, String.Bytes, String.Size);
		} while(NumberOfBytesRead > 0);
		waitpid(ProcessID, &ExitCode, WUNTRACED);
		close(MasterFD);
		


		FailedToExecute[0] = (WIFEXITED(ExitCode) && WEXITSTATUS(ExitCode) != 0);
	}

	return ProcessStatus == 0;
}

str8 CompileCommandFromBuildOptions(memory_arena *Arena, build_options *BuildOptions, str8 HashedFilename, str8 SourceFilename)
{
	str8 DebugOrRelease[2] =
	{
		Str8("-g -O0"), Str8("-O2")
	};

	str8 Compilers[2] =
	{
		Str8("clang"), Str8("gcc")
	};

	str8 ObjectiveC[2] =
	{
		Str8(""), Str8("-ObjC -fobjc-arc")
	};

	b32 IsObjectiveCFile = Str8EndsWith(SourceFilename, Str8(".m"));

	str8_list IncludePathsWithFlag = {0};
	for (str8_list_node *Node = BuildOptions->IncludePaths.First; Node != Null; Node = Node->Next)
	{
		Str8ListAppend(Arena, &IncludePathsWithFlag, Str8PushF(Arena, "-I%.*s ", Str8ToPrintfArgs(Node->String)));
	}

	str8 CompileCommand = Str8PushF(
		Arena,
		"%.*s %.*s %.*s -c %.*s %.*s -o%.*s%.*s %.*s ",
		Str8ToPrintfArgs(Compilers[BuildOptions->Compiler]),
		Str8ToPrintfArgs(Str8ListJoin(Arena, BuildOptions->ExtraCompileFlags)),
		Str8ToPrintfArgs(ObjectiveC[IsObjectiveCFile]),
		Str8ToPrintfArgs(SourceFilename),
		Str8ToPrintfArgs(DebugOrRelease[BuildOptions->Optimise]),
		Str8ToPrintfArgs(BuildOptions->OutputPath),
		Str8ToPrintfArgs(HashedFilename),
		Str8ToPrintfArgs(Str8ListJoin(Arena, IncludePathsWithFlag)));

	return CompileCommand;
}

str8 LinkCommandFromBuildOptions(memory_arena *Arena, build_options *BuildOptions, str8_array ObjectFiles)
{
	str8 LinkCommand = Str8PushF(
		Arena,
		"clang %.*s -o %.*s%.*s %.*s",
		Str8ToPrintfArgs(Str8ListJoin(Arena, BuildOptions->ExtraLinkFlags)),
		Str8ToPrintfArgs(BuildOptions->OutputPath),
		Str8ToPrintfArgs(BuildOptions->OutputName),
		Str8ToPrintfArgs(Str8ArrayJoin(Arena, ObjectFiles))
	);

	return LinkCommand;
}

#define Entry(Data) void *Entry(void *Data)

Entry(Data);


typedef struct barrier
{
	atomic_ullong Generation;
	atomic_ullong LanesWaiting;
	s64 LaneCount;
}
barrier;

typedef struct shared_wave_info
{
	s32 ArgCount;
	char **Args;

	barrier *Barrier;

	s64 LaneCount;

	memory_arena Arena;
	build_options BuildOptions;


	atomic_llong Data[4096];
}
shared_wave_info;

typedef struct wave_info
{
	shared_wave_info *Shared;
	s32 Lane;
}
wave_info;

/*
Based on Raymond Chen's article on synchronization barriers
https://devblogs.microsoft.com/oldnewthing/20160824-00/?p=94155
*/
void WaveBarrier(barrier *Barrier)
{
	s64 Generation = atomic_load_explicit(&Barrier->Generation, memory_order_acquire);
	s64 LanesWaiting = atomic_fetch_add_explicit(&Barrier->LanesWaiting, 1, memory_order_acq_rel);

	if(LanesWaiting < Barrier->LaneCount - 1)
	{
		while(atomic_load_explicit(&Barrier->Generation, memory_order_acquire) == Generation)
		{
			os_sync_wait_on_address(&Barrier->Generation, Generation, sizeof(atomic_llong), OS_SYNC_WAIT_ON_ADDRESS_SHARED);
		}
	}
	else if(LanesWaiting == Barrier->LaneCount - 1)
	{
		atomic_store_explicit(&Barrier->LanesWaiting, 0, memory_order_release);
		atomic_fetch_add_explicit(&Barrier->Generation, 1, memory_order_release);
		os_sync_wake_by_address_all(&Barrier->Generation, sizeof(atomic_llong), OS_SYNC_WAKE_BY_ADDRESS_SHARED);
	}
}

s64 LaneValueFromTotal(wave_info *WaveInfo, s64 Count)
{
	s64 Base = Count / WaveInfo->Shared->LaneCount;
	s64 Remainder = Count % WaveInfo->Shared->LaneCount;
	s64 Result = Count / WaveInfo->Shared->LaneCount + (WaveInfo->Lane < Remainder ? 1 : 0);

	if (Count < WaveInfo->Shared->LaneCount)
	{
		Result = (s64)(WaveInfo->Lane < Count);
	}

	return Result;
}

void Dispatch(shared_wave_info *Shared, s64 LaneCount)
{
	wave_info *Entries = (wave_info*)ArenaPush(&Shared->Arena, LaneCount*sizeof(wave_info));
	pthread_t *Waves = (pthread_t*)ArenaPush(&Shared->Arena, LaneCount*sizeof(pthread_t));

	barrier Barrier = {0};

	Shared->LaneCount = LaneCount;
	Barrier.LaneCount = LaneCount;
	for (s64 Lane = 0; Lane < LaneCount; Lane++)
	{
		Entries[Lane].Shared = Shared;
		Entries[Lane].Lane = Lane;
		Entries[Lane].Shared->Barrier = &Barrier;
		assert(pthread_create(Waves + Lane, Null, Entry, Entries + Lane) == 0);
	}

	for (s64 Lane = 0; Lane < LaneCount; Lane++)
	{
		pthread_join(Waves[Lane], Null);
	}
}

b32 WaveIsFirstLane(wave_info *WaveInfo)
{
	return WaveInfo->Lane == 0;
}

u8 *ArenaPushTransient(memory_arena *Arena, s64 Bytes);

void BroadcastBytes(wave_info *WaveInfo, void *Bytes, s64 ByteCount)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	u8 *Result = Null;
	if(WaveIsFirstLane(WaveInfo))
	{
		Result = ArenaPushTransient(&WaveInfo->Shared->Arena, ByteCount);
		MemoryCopy(Result, Bytes, ByteCount);
	}
	WaveBarrier(WaveInfo->Shared->Barrier);
	Result = (u8*)(WaveInfo->Shared->Arena.Start + WaveInfo->Shared->Arena.At);
	MemoryCopy(Bytes, Result, ByteCount);
	WaveBarrier(WaveInfo->Shared->Barrier);
}

#define BroadcastToAllLanes(WaveInfo, Variable) BroadcastBytes(WaveInfo, &Variable, sizeof(Variable))

#define SharedBetweenLanes(WaveInfo, Variable)

s64 WaveGetLaneIndex(wave_info *WaveInfo)
{
	return WaveInfo->Lane;
}
/*
This could be faster probably but it's fine and works,
I don't own a threadripper so this will be fine for
32 core computers...

The following link shows a faster version that would work better.

GPU Gems 3
https://www.youtube.com/watch?v=1G8CZioSjnM
*/
u64 InclusiveWavePrefixSum(wave_info *WaveInfo, u64 Value)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	WaveInfo->Shared->Data[WaveInfo->Lane] = Value;
	WaveBarrier(WaveInfo->Shared->Barrier);

	int PerLaneSum = 0;
	for(int I = 0; I <= WaveInfo->Lane; I++)
	{
		PerLaneSum += WaveInfo->Shared->Data[I];
	}

	WaveBarrier(WaveInfo->Shared->Barrier);
	return PerLaneSum;
}

u64 ExclusiveWavePrefixSum(wave_info *WaveInfo, u64 Value)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	WaveInfo->Shared->Data[WaveInfo->Lane] = Value;
	WaveBarrier(WaveInfo->Shared->Barrier);

	u64 PerLaneSum = 0;
	for(int I = 0; I < WaveInfo->Lane; I++)
	{
		PerLaneSum += WaveInfo->Shared->Data[I];
	}
	WaveBarrier(WaveInfo->Shared->Barrier);
	return PerLaneSum;
}

b32 WaveAnyTrue(wave_info *WaveInfo, b32 Expression)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	atomic_store_explicit(WaveInfo->Shared->Data + 0, 0, memory_order_release);
	WaveBarrier(WaveInfo->Shared->Barrier);
	atomic_fetch_add_explicit(WaveInfo->Shared->Data + 0, Expression, memory_order_consume);
	WaveBarrier(WaveInfo->Shared->Barrier);
	return atomic_load_explicit(WaveInfo->Shared->Data + 0, memory_order_acquire) > 0;
}

#elif defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define MemoryCommit(Address, NumberOfBytes) VirtualAlloc((void*)(Address), NumberOfBytes, MEM_COMMIT, PAGE_READWRITE)
#define MemoryReserve(NumberOfBytes) (u8*)VirtualAlloc((void*)0, NumberOfBytes, MEM_RESERVE, PAGE_READWRITE)

#define MemoryCopy(Destination, Source, NumberOfBytes) RtlCopyMemory(Destination, Source, NumberOfBytes)
#define MemoryZero(Destination, NumberOfBytes) RtlZeroMemory(Destination, NumberOfBytes)

operating_system GetOperatingSystem()
{
	return OS_WINDOWS;
}

u64 GetPageSize()
{
	SYSTEM_INFO SystemInfo = {0};
	GetSystemInfo(&SystemInfo);

	return SystemInfo.dwPageSize;
}

str8 LoadEntireFileIntoMemory(memory_arena *Arena, str8 Filename)
{
	HANDLE FileHandle = CreateFileA(CStrFromStr8(Arena, Filename),
					GENERIC_READ,
					FILE_SHARE_READ,
					Null,
					OPEN_EXISTING,
					FILE_ATTRIBUTE_NORMAL,
					Null);

	if (FileHandle == INVALID_HANDLE_VALUE)
	{
		printf("File: %.*s not found\n", Str8ToPrintfArgs(Filename));
		return (str8){0};
	}

	LARGE_INTEGER FileSize;
	DWORD BytesRead;
	GetFileSizeEx(FileHandle, &FileSize);

	u8* BackingMemory = ArenaPush(Arena, (u64)FileSize.QuadPart+1);
	BackingMemory[FileSize.QuadPart] = 0;

	str8 Result = {0};
	Result.Bytes = (s8*)BackingMemory;
	Result.Size = FileSize.QuadPart;

	ReadFile(FileHandle, BackingMemory, FileSize.QuadPart, &BytesRead, Null);

	CloseHandle(FileHandle);

	return Result;
}

void WriteStringToDisk(memory_arena *Arena, str8 DestinationPath, str8 StringToWrite)
{
	HANDLE FileHandle = CreateFileA(CStrFromStr8(Arena, DestinationPath),
					GENERIC_WRITE,
					0,
					Null,
					CREATE_ALWAYS,
					FILE_ATTRIBUTE_NORMAL,
					Null);

	DWORD BytesWritten = 0;
	WriteFile(FileHandle, StringToWrite.Bytes, StringToWrite.Size, &BytesWritten, Null);
	CloseHandle(FileHandle);
}

void AppendSourceFilesInFolder(memory_arena *Arena, str8_list *SourceFilesFromFolder, str8 Path)
{
	str8 PathWithWildcard = Str8PushF(Arena, "%.*s", Str8ToPrintfArgs(Path));
	str8_list Entries = ListOfDirectoryEntriesFromPath(Arena, PathWithWildcard);
	for(str8_list_node *Entry = Entries.First; Entry != Null; Entry = Entry->Next)
	{
		if(Str8EndsWith(Entry->String, Str8(".c")))
		{
			str8 SourceFilepath = Str8PushF(Arena, "%.*s/%.*s",
											Str8ToPrintfArgs(Path),
											Str8ToPrintfArgs(Entry->String));
			Str8ListAppend(Arena, SourceFilesFromFolder, SourceFilepath);
		}
	}
}

str8 GetExecutableDirectory(memory_arena *Arena)
{
	DWORD NumberOfBytes = GetCurrentDirectoryA(0, 0);
	u8* BackingMemory = ArenaPush(Arena, NumberOfBytes);

	GetCurrentDirectoryA(NumberOfBytes, (LPSTR)BackingMemory);

	str8 Result = {0};
	Result.Size = NumberOfBytes;
	Result.Bytes = (s8*)BackingMemory;

	return Result;
}

b32 PathExists(memory_arena *Arena, str8 Filename)
{
	DWORD FileAttributes = GetFileAttributesA((LPCSTR)CStrFromStr8(Arena, Filename));

	return FileAttributes != INVALID_FILE_ATTRIBUTES && !(FileAttributes & FILE_ATTRIBUTE_DIRECTORY);
}

s64 AtomicIncrement(s64 volatile *Addend, s64 Value)
{
	return InterlockedExchangeAdd64(Addend, Value);
}

u64 TimeStampNow()
{
	LARGE_INTEGER Stamp = {0};
	QueryPerformanceCounter(&Stamp);
	return Stamp.QuadPart;
}

f32 MilliSecondsFromTimeStamp(u64 TimeStamp)
{
	LARGE_INTEGER Frequency = {0};
	QueryPerformanceFrequency(&Frequency);

	return (f32)(1000.0*(TimeStamp) / Frequency.QuadPart);

}

s64 GetNumberOfCPUs()
{
	SYSTEM_INFO SystemInfo = {0};
	GetSystemInfo(&SystemInfo);

	return SystemInfo.dwNumberOfProcessors;
}

void DeleteFileFromDisk(memory_arena *Arena, str8 Filename)
{
	DeleteFileA(CStrFromStr8(Arena, Filename));
}

b32 ExecuteCommand(memory_arena *Arena, str8 EntireCommandAndArguments, b32 *FailedToExecute)
{
	STARTUPINFOA StartupInfo = {0};
	PROCESS_INFORMATION ProcessInfo = {0};

	SECURITY_ATTRIBUTES SecurityAttributes = {0};
	SecurityAttributes.nLength = sizeof(SECURITY_ATTRIBUTES);
	SecurityAttributes.bInheritHandle = True;

	HANDLE StdOutHandleRead = 0;
	HANDLE StdOutHandleWrite = 0;

	CreatePipe(&StdOutHandleRead, &StdOutHandleWrite, &SecurityAttributes, 0);

	b32 ProcessStatus = CreateProcessA(0, CStrFromStr8(Arena, EntireCommandAndArguments),
									   0, 0, 1, 0, 0, 0, &StartupInfo, &ProcessInfo);
	if (ProcessStatus)
	{

		WaitForSingleObject(ProcessInfo.hProcess, INFINITE);

		DWORD ExitCode;
		GetExitCodeProcess(ProcessInfo.hProcess, &ExitCode);
		CloseHandle(ProcessInfo.hProcess);
		CloseHandle(ProcessInfo.hThread);
		CloseHandle(StdOutHandleWrite);

		FailedToExecute[0] = ExitCode != 0;
		DWORD NumberOfBytesRead = 0;
		str8_list StdOutList = {0};
		for (;;)
		{
			u8* BackingMemory = ArenaPush(Arena, 4096);
			BOOL Success = ReadFile(StdOutHandleRead, BackingMemory, 4096, &NumberOfBytesRead, NULL);
			if (!Success || NumberOfBytesRead == 0)
			{
				break;
			}
			str8 String = {.Bytes = (s8*)BackingMemory, .Size = NumberOfBytesRead };
			Str8ListAppend(Arena, &StdOutList, String);
		}
		str8 OutputString = Str8ListJoin(Arena, StdOutList);
		printf("%.*s", Str8ToPrintfArgs(OutputString));
	}

	return ProcessStatus;
}

str8 CompileCommandFromBuildOptions(memory_arena *Arena, build_options *BuildOptions, str8 HashedFilename, str8 SourceFilename)
{
	str8 DebugOrRelease[2] =
	{
		Str8("/Zi /Od"), Str8("/O2")
	};

	str8 Compilers[2] =
	{
		Str8("cl.exe"),
		Str8("clang-cl")
	};

	str8_list IncludePathsWithFlag = {0};
	for (str8_list_node *Node = BuildOptions->IncludePaths.First; Node != Null; Node = Node->Next)
	{
		Str8ListAppend(Arena, &IncludePathsWithFlag, Str8PushF(Arena, "-I%.*s ", Str8ToPrintfArgs(Node->String)));
	}

	str8 CompileCommand = Str8PushF(
		Arena,
		"%.*s /c /TC %.*s /nologo /FS /EHsc %.*s %.*s /Fo%.*s%.*s %.*s ",
		Str8ToPrintfArgs(Compilers[BuildOptions->Compiler]),
		Str8ToPrintfArgs(Str8ListJoin(Arena, BuildOptions->ExtraCompileFlags)),
		Str8ToPrintfArgs(SourceFilename),
		Str8ToPrintfArgs(DebugOrRelease[BuildOptions->Optimise]),
		Str8ToPrintfArgs(BuildOptions->OutputPath),
		Str8ToPrintfArgs(HashedFilename),
		Str8ToPrintfArgs(Str8ListJoin(Arena, IncludePathsWithFlag)));

	return CompileCommand;
}

str8 LinkCommandFromBuildOptions(memory_arena *Arena, build_options *BuildOptions, str8_array ObjectFiles)
{
	str8 LinkCommand = Str8PushF(
		Arena,
		"link.exe /OPT:NOREF /OPT:NOICF /nologo /INCREMENTAL:NO /DEBUG %.*s/PDB:build/%.*s.pdb /OUT:%.*s%.*s.exe %.*s",
		Str8ToPrintfArgs(Str8ListJoin(Arena, BuildOptions->ExtraLinkFlags)),
		Str8ToPrintfArgs(BuildOptions->OutputName),
		Str8ToPrintfArgs(BuildOptions->OutputPath),
		Str8ToPrintfArgs(BuildOptions->OutputName),
		Str8ToPrintfArgs(Str8ArrayJoin(Arena, ObjectFiles))
	);

	return LinkCommand;
}

#define Entry(Data) DWORD WINAPI Entry(void *Data)

Entry(Data);

typedef struct shared_wave_info
{
	s32 ArgCount;
	char **Args;
	RTL_BARRIER *Barrier;

	s64 LaneCount;

	memory_arena Arena;
	build_options BuildOptions;


	atomic_llong Data[4096];
}
shared_wave_info;

typedef struct wave_info
{
	shared_wave_info *Shared;
	s32 Lane;
}
wave_info;

void WaveBarrier(RTL_BARRIER *Barrier)
{
	EnterSynchronizationBarrier(Barrier, SYNCHRONIZATION_BARRIER_FLAGS_BLOCK_ONLY);
}

s64 LaneValueFromTotal(wave_info *WaveInfo, s64 Count)
{
	s64 Base = Count / WaveInfo->Shared->LaneCount;
	s64 Remainder = Count % WaveInfo->Shared->LaneCount;
	s64 Result = Count / WaveInfo->Shared->LaneCount + (WaveInfo->Lane < Remainder ? 1 : 0);

	if (Count < WaveInfo->Shared->LaneCount)
	{
		Result = (s64)(WaveInfo->Lane < Count);
	}

	return Result;
}

void Dispatch(shared_wave_info *Shared, s64 LaneCount)
{
	wave_info *Entries = (wave_info*)ArenaPush(&Shared->Arena, LaneCount*sizeof(wave_info));
	HANDLE *Waves = (HANDLE*)ArenaPush(&Shared->Arena, LaneCount*sizeof(HANDLE));

	RTL_BARRIER Barrier;

	Shared->LaneCount = LaneCount;
	InitializeSynchronizationBarrier(&Barrier, LaneCount, -1);
	for (s64 Lane = 0; Lane < LaneCount; Lane++)
	{
		Entries[Lane].Shared = Shared;
		Entries[Lane].Lane = Lane;
		Entries[Lane].Shared->Barrier = &Barrier;
		DWORD ThreadID;
		Waves[Lane] = CreateThread(0, 0, Entry, Entries + Lane, 0, &ThreadID);
	}

	WaitForMultipleObjects(LaneCount, Waves, True, INFINITE);
}

b32 WaveIsFirstLane(wave_info *WaveInfo)
{
	return WaveInfo->Lane == 0;
}

u8 *ArenaPushTransient(memory_arena *Arena, s64 Bytes);

void BroadcastBytes(wave_info *WaveInfo, void *Bytes, s64 ByteCount)
{
	u8 *Result = Null;
	if(WaveIsFirstLane(WaveInfo))
	{
		Result = ArenaPushTransient(&WaveInfo->Shared->Arena, ByteCount);
		MemoryCopy(Result, Bytes, ByteCount);
	}
	WaveBarrier(WaveInfo->Shared->Barrier);
	Result = (u8*)(WaveInfo->Shared->Arena.Start + WaveInfo->Shared->Arena.At);
	MemoryCopy(Bytes, Result, ByteCount);
	WaveBarrier(WaveInfo->Shared->Barrier);
}

#define BroadcastToAllLanes(WaveInfo, Variable) BroadcastBytes(WaveInfo, &Variable, sizeof(Variable))

#define SharedBetweenLanes(WaveInfo, Variable)

s64 WaveGetLaneIndex(wave_info *WaveInfo)
{
	return WaveInfo->Lane;
}

/*
GPU Gems 3
https://www.youtube.com/watch?v=1G8CZioSjnM
*/
u64 InclusiveWavePrefixSum(wave_info *WaveInfo, u64 Value)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	WaveInfo->Shared->Data[WaveInfo->Lane] = Value;
	WaveBarrier(WaveInfo->Shared->Barrier);

	int PerLaneSum = 0;
	for(int I = 0; I <= WaveInfo->Lane; I++)
	{
		PerLaneSum += WaveInfo->Shared->Data[I];
	}

	WaveBarrier(WaveInfo->Shared->Barrier);
	return PerLaneSum;
}

u64 ExclusiveWavePrefixSum(wave_info *WaveInfo, u64 Value)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	WaveInfo->Shared->Data[WaveInfo->Lane] = Value;
	WaveBarrier(WaveInfo->Shared->Barrier);

	u64 PerLaneSum = 0;
	for(int I = 0; I < WaveInfo->Lane; I++)
	{
		PerLaneSum += WaveInfo->Shared->Data[I];
	}
	WaveBarrier(WaveInfo->Shared->Barrier);
	return PerLaneSum;
}

b32 WaveAnyTrue(wave_info *WaveInfo, b32 Expression)
{
	WaveBarrier(WaveInfo->Shared->Barrier);
	atomic_store_explicit(WaveInfo->Shared->Data + 0, 0, memory_order_release);
	WaveBarrier(WaveInfo->Shared->Barrier);
	atomic_fetch_add_explicit(WaveInfo->Shared->Data + 0, Expression, memory_order_consume);
	WaveBarrier(WaveInfo->Shared->Barrier);
	return atomic_load_explicit(WaveInfo->Shared->Data + 0, memory_order_acquire) > 0;
}

str8_list ListOfDirectoryEntriesFromPath(memory_arena *Arena, str8 Path)
{
	str8_list Entries = { 0 };

	WIN32_FIND_DATAA FindData = {0};
	str8 Directory = Str8PushF(Arena, "%.*s\\*", Str8ToPrintfArgs(Path));
	HANDLE FindHandle = FindFirstFileA(CStrFromStr8(Arena, Directory), &FindData);

	b32 NextFile = FindHandle != INVALID_HANDLE_VALUE;
	for(;NextFile != False; NextFile = FindNextFileA(FindHandle, &FindData))
	{
		if(FindData.dwFileAttributes != INVALID_FILE_ATTRIBUTES && !(FindData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
		{
			Str8ListAppend(Arena, &Entries, Str8PushF(Arena, "%s", FindData.cFileName));
		}
	}
	return Entries;
}

int MoveFileOnDisk(memory_arena *Arena, str8 Source, str8 Destination)
{
	return MoveFileExA(CStrFromStr8(Arena, Source),
					   CStrFromStr8(Arena, Destination),
					   MOVEFILE_COPY_ALLOWED | MOVEFILE_REPLACE_EXISTING);
}
#endif

u8* ArenaPush(memory_arena *Arena, s64 Bytes)
{
	if(Arena->At + Bytes >= Arena->Committed)
	{
		s64 BytesNeeded = (Arena->At + Bytes - Arena->Committed);
		u64 BytesToCommit = BytesNeeded + GetPageSize() - (BytesNeeded % GetPageSize());
		MemoryCommit(Arena->Start + Arena->Committed, BytesToCommit);
		Arena->Committed += BytesToCommit;
	}
	u8* Memory = Arena->Start + Arena->At;
	Arena->At += Bytes;
	MemoryZero(Memory, Bytes);

	return Memory;
}

u8 *ArenaPushTransient(memory_arena *Arena, s64 Bytes)
{
	if(Arena->At + Bytes >= Arena->Committed)
	{
		s64 BytesNeeded = (Arena->At + Bytes - Arena->Committed);
		u64 BytesToCommit = BytesNeeded + GetPageSize() - (BytesNeeded % GetPageSize());
		MemoryCommit(Arena->Start + Arena->Committed, BytesToCommit);
		Arena->Committed += BytesToCommit;
	}
	u8* Memory = Arena->Start + Arena->At;

	return Memory;
}

str8 Str8PushFV(memory_arena *Arena, char *Format, va_list InputArgList)
{
	va_list ArgList;
	va_copy(ArgList, InputArgList);
	u32 BytesNeeded = vsnprintf(0, 0, Format, InputArgList) +1;
	str8 Result = {0};
	Result.Bytes = (s8*)ArenaPush(Arena, BytesNeeded);
	Result.Size = vsnprintf((char *)Result.Bytes, BytesNeeded, Format, ArgList);
	Result.Bytes[Result.Size] = 0;
	va_end(ArgList);
	return Result;
}

str8 Str8PushF(memory_arena *Arena, char *Format, ...)
{
	va_list args;
	va_start(args, Format);
	str8 Result = Str8PushFV(Arena, Format, args);
	va_end(args);
	return Result;
}

char *CStrFromStr8(memory_arena *Arena, str8 String)
{
	char *Result = (char *)ArenaPush(Arena, String.Size + 1);
	MemoryCopy(Result, String.Bytes, String.Size);
	return Result;
}

b32 Str8Equal(str8 A, str8 B)
{
	if (A.Size != B.Size)
		return False;
	for (u64 Index = 0; Index < A.Size; Index++)
	{
		if (A.Bytes[Index] != B.Bytes[Index])
		{
			return False;
		}
	}
	return True;
}

b32  Str8EndsWith(str8 String, str8 EndsWith)
{
	str8 SubString = String;
	SubString.Bytes += String.Size - EndsWith.Size;
	SubString.Size = EndsWith.Size;
	return Str8Equal(SubString, EndsWith);
}

void Str8ListAppend(memory_arena *Arena, str8_list *List, str8 String)
{
	str8_list_node *Node = ArenaPushType(Arena, str8_list_node);
	Node->String = Str8PushF(Arena, "%.*s", Str8ToPrintfArgs(String));
	if (List->First == Null)
	{
		List->First = Node;
		List->Last = List->First;
	}
	else
	{
		List->Last->Next = Node;
		Node->Previous = List->Last;
		List->Last = Node;
	}
}

str8 Str8ListJoin(memory_arena *Arena, str8_list List)
{
	u64 BytesToAllocate = 0;
	for (str8_list_node *Node = List.First; Node != Null; Node = Node->Next)
	{
		BytesToAllocate += Node->String.Size;
	}
	u8 *Bytes = ArenaPush(Arena, BytesToAllocate);
	u64 At = 0;
	for (str8_list_node *Node = List.First; Node != Null; Node = Node->Next)
	{
		MemoryCopy(Bytes + At, Node->String.Bytes, Node->String.Size);
		At += Node->String.Size;
	}
	str8 Result = {.Bytes = (s8*)Bytes, .Size = BytesToAllocate};

	return Result;
}

str8 Str8ArrayJoin(memory_arena *Arena, str8_array Array)
{
	u64 BytesToAllocate = 0;
	for (int I = 0; I < Array.Count; I++)
	{
		BytesToAllocate += Array.Items[I].Size;
	}
	u8 *Bytes = ArenaPush(Arena, BytesToAllocate);
	u64 At = 0;
	for (int I = 0; I < Array.Count; I++)
	{
		MemoryCopy(Bytes + At, Array.Items[I].Bytes, Array.Items[I].Size);
		At += Array.Items[I].Size;
	}
	str8 Result = {.Bytes = (s8*)Bytes, .Size = BytesToAllocate};

	return Result;
}

str8_array Str8ArrayFromList(memory_arena *Arena, str8_list List)
{
	str8_array Result = {0};
	s64 Count = 0;
	for(str8_list_node *Entry = List.First; Entry != Null; Entry = Entry->Next)
	{
		Count++;
	}
	Result.Count = Count;
	Result.Items = (str8*)ArenaPush(Arena, sizeof(str8)*Count);
	s64 Index = 0;
	for(str8_list_node *Entry = List.First; Entry != Null; Entry = Entry->Next)
	{
		Result.Items[Index++] = Entry->String;
	}
	return Result;
}

#define FNV_64_PRIME ((u64)0x100000001b3ULL)
#define FNV_HASH_START ((u64)0xcbf29ce484222325ULL)
void FNVHash64(u64 *Hash, str8 String)
{
	for (s64 Index = 0; Index < String.Size; Index++)
	{

		*Hash *= FNV_64_PRIME;
		*Hash ^= (u64)String.Bytes[Index];
	}
}

b32 AdvanceN(str8 File, u64 *At, u64 N)
{
	if (*At + N <= File.Size)
	{
		*At += N;
		return True;
	}
	return False;
}

void GobbleWhitespace(str8 File, u64 *At)
{
	while (*At < File.Size)
	{
		u64 Byte = File.Bytes[*At];
		switch (Byte)
		{
		case ' ':
		case '\r':
		case '\t':
		case '\n':
		{
			if(AdvanceN(File, At, 1) == False)
			{
				return;
			}
		}
		break;
		default:
		{
			return;
		}
		break;
		}
	}
}

void GobbleUpToWhitespace(str8 File, u64 *At)
{
	while (*At < File.Size)
	{
		u64 Byte = File.Bytes[*At];
		switch (Byte)
		{
		case ' ':
		case '\r':
		case '\t':
		case '\n':
		{
			return;
		}
		break;
		default:
		{
			if(AdvanceN(File, At, 1) == False)
			{
				return;
			}
		}
		break;
		}
	}
}

str8 Str8UpToLastCharacter(memory_arena *Arena, str8 InputPath, u8 Character)
{
	s64 SizeUptoLastCharacter = InputPath.Size - 1;
	b32 FoundCharacter = False;
	for (; SizeUptoLastCharacter >= 0; SizeUptoLastCharacter--)
	{
		if (InputPath.Bytes[SizeUptoLastCharacter] == Character)
		{
			FoundCharacter = True;
			break;
		}
	}
	str8 Path = {0};
	if (FoundCharacter)
	{
		Path.Size = SizeUptoLastCharacter;
		Path.Bytes = (s8*)ArenaPush(Arena, SizeUptoLastCharacter);
		MemoryCopy(Path.Bytes, InputPath.Bytes, SizeUptoLastCharacter);
	}
	return Path;
}

str8 Str8FromLastCharacter(memory_arena *Arena, str8 InputPath, u8 Character)
{
	s64 StartIndex = 0;
	b32 FoundCharacter = False;
	for (int I = InputPath.Size; I > 0; I--)
	{
		if (InputPath.Bytes[I-1] == Character)
		{
			FoundCharacter = True;
			StartIndex = I;
			break;
		}
	}

	str8 Result = {0};
	if (FoundCharacter)
	{
		Result.Size = InputPath.Size - StartIndex;
		Result.Bytes = (s8*)ArenaPush(Arena, Result.Size);
		MemoryCopy(Result.Bytes, InputPath.Bytes + StartIndex, Result.Size);
	}
	return Result;
}


b32 Str8ListContainsStr8(str8_list *List, str8 String)
{
	for(str8_list_node *Node = List->First; Node != 0; Node = Node->Next)
	{
		if(Str8Equal(Node->String, String)) return True;
	}
	return False;
}

void FindAllIncludesInFile(memory_arena *Arena, str8 Filename, str8_list IncludePaths, str8_list *IncludeChainFiles, str8_list *VisitedFiles)
{
	if(Str8ListContainsStr8(VisitedFiles, Filename)) return;
	Str8ListAppend(Arena, VisitedFiles, Filename);

	str8 CurrentFile = LoadEntireFileIntoMemory(Arena, Filename);
	Str8ListAppend(Arena, IncludeChainFiles, CurrentFile);

	b32 InLineComment = False;
	b32 InBlockComment = False;
	for (u64 At = 0; At < CurrentFile.Size; At++)
	{
		u8 Byte = CurrentFile.Bytes[At];

		if(InLineComment)
		{
			if(Byte == '\n') InLineComment = False;
			continue;
		}

		if(InBlockComment)
		{
			if(Byte == '*' && At + 1 < (u64)CurrentFile.Size && CurrentFile.Bytes[At+1] == '/')
			{
				InBlockComment = False;
				At++;
			}
			continue;
		}

		if(Byte == '/' && At + 1 < (u64)CurrentFile.Size)
		{
			if(CurrentFile.Bytes[At+1] == '/') { InLineComment = True; At++; continue; }
			if(CurrentFile.Bytes[At+1] == '*') { InBlockComment = True; At++; continue; }
		}

		if (Byte == '#')
		{
			if (AdvanceN(CurrentFile, &At, 1) == False)
			{
				return;
			}
			str8 Token = {0};
			Token.Bytes = CurrentFile.Bytes + At;
			str8 IncludeToken = Str8("include");
			Token.Size = IncludeToken.Size;
			if (At + Token.Size < CurrentFile.Size)
			{
				if (Str8Equal(Token, IncludeToken))
				{
					AdvanceN(CurrentFile, &At, Token.Size);
					GobbleWhitespace(CurrentFile, &At);
					if (CurrentFile.Bytes[At] == '"')
					{
						if (AdvanceN(CurrentFile, &At, 1))
						{
							str8 IncludePath = {0};
							IncludePath.Bytes = CurrentFile.Bytes + At;
							for (; AdvanceN(CurrentFile, &At, 1) && CurrentFile.Bytes[At] != '"';);
							IncludePath.Size = CurrentFile.Bytes + At - IncludePath.Bytes;
							str8 SourceDir = Str8UpToLastCharacter(Arena, Filename, '/');
							str8 SourceDirPlusIncludePath = Str8PushF(Arena, "%.*s/%.*s", Str8ToPrintfArgs(SourceDir), Str8ToPrintfArgs(IncludePath));
							b32 FoundFile = False;
							str8_list AttemptedIncludes = {0};
							if (PathExists(Arena, SourceDirPlusIncludePath))
							{
								FoundFile = True;
								FindAllIncludesInFile(Arena, SourceDirPlusIncludePath, IncludePaths, IncludeChainFiles, VisitedFiles);
							}
							else
							{
								for (str8_list_node *Node = IncludePaths.First; Node != 0; Node = Node->Next)
								{
									str8 FullPath = Str8PushF(
										Arena,
										"%.*s/%.*s",
										Str8ToPrintfArgs(Str8UpToLastCharacter(Arena, Node->String, '/')),
										Str8ToPrintfArgs(IncludePath));

									if(PathExists(Arena, FullPath))
									{
										FoundFile = True;
										FindAllIncludesInFile(Arena, FullPath, IncludePaths, IncludeChainFiles, VisitedFiles);
										break;
									}
									else
									{
										Str8ListAppend(Arena, &AttemptedIncludes, FullPath);
									}
								}
							}

							if (FoundFile == False)
							{
								return;
							}
						}
					}
				}
			}
		}
	}
}

void GenerateEmbedHeader(memory_arena *Arena, str8 DestinationPath)
{
	str8 FilePath = Str8PushF(Arena, "%.*s/embed.h", Str8ToPrintfArgs(DestinationPath));
	WriteStringToDisk(Arena, FilePath, Str8("#pragma once \n typedef struct embed_data { unsigned char *Data; unsigned long long Length; } embed_data;"));
}

void EmbedFiles(memory_arena *Arena, str8_list SourcePaths, str8 DestinationPath, str8_list Names)
{
	str8_list Embed = {0};
	str8_list_node *Name = Names.First;

	str8 HeaderPath = Str8PushF(Arena, "%.*s.h", Str8ToPrintfArgs(Str8UpToLastCharacter(Arena, DestinationPath, '.')));

	Str8ListAppend(Arena, &Embed, Str8("#pragma once\n #include \"embed.h\" \n"));

	for(str8_list_node *SourcePath = SourcePaths.First;
		SourcePath != Null;
		SourcePath = SourcePath->Next)
	{
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "extern embed_data %.*s;\n", Str8ToPrintfArgs(Name->String)));
		Name = Name->Next;
	}

	WriteStringToDisk(Arena, HeaderPath, Str8ListJoin(Arena, Embed));

	Embed = (str8_list){0};
	Name = Names.First;

	Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "#include \"%.*s\"\n", Str8ToPrintfArgs(Str8FromLastCharacter(Arena, HeaderPath, '/'))));

	for(str8_list_node *SourcePath = SourcePaths.First;
		SourcePath != Null;
		SourcePath = SourcePath->Next)
	{
		if(!Name)
		{
			printf(F_ERROR "Number of names do not match number files.\n\n");
			return;
		}
		str8 File = LoadEntireFileIntoMemory(Arena, SourcePath->String);
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "static unsigned char %.*sData[] =\n{\n", Str8ToPrintfArgs(Name->String)));
		for(s64 At = 0; At < File.Size;)
		{
			u8* Byte = (u8*)(File.Bytes + At);
			if(At + 16 <= File.Size)
			{
				str8 Elements = Str8PushF(Arena,
					"    0x%02x, 0x%02x, 0x%02x, 0x%02x,\n"
					"    0x%02x, 0x%02x, 0x%02x, 0x%02x,\n"
					"    0x%02x, 0x%02x, 0x%02x, 0x%02x,\n"
					"    0x%02x, 0x%02x, 0x%02x, 0x%02x,\n",
					Byte[0],  Byte[1],  Byte[2],  Byte[3],
					Byte[4],  Byte[5],  Byte[6],  Byte[7],
					Byte[8],  Byte[9],  Byte[10], Byte[11],
					Byte[12], Byte[13], Byte[14], Byte[15]
				);
				Str8ListAppend(Arena, &Embed, Elements);
				At += 16;
			}
			else
			{
				str8 Element = {0};
				if(At % 4 == 0)
				{
					Element = Str8PushF(Arena, "    0x%02x,", Byte[0]);
				}
				else
				{
					if((At % 4) % 3 == 0)
					{
						Element = Str8PushF(Arena, "0x%02x,\n", Byte[0]);
					}
					else
					{
						Element = Str8PushF(Arena, "0x%02x, ", Byte[0]);
					}
				}
				Str8ListAppend(Arena, &Embed, Element);
				At += 1;
			}
		}
		Str8ListAppend(Arena, &Embed, Str8("\n};\n\n"));
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "embed_data %.*s = {\n", Str8ToPrintfArgs(Name->String)));
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "	.Data = %.*sData,\n", Str8ToPrintfArgs(Name->String)));
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "	.Length = %llu,\n",  File.Size));
		Str8ListAppend(Arena, &Embed, Str8PushF(Arena, "};\n"));
		Name = Name->Next;
	}

	str8 JoinedEmbed = Str8ListJoin(Arena, Embed);
	WriteStringToDisk(Arena, DestinationPath, JoinedEmbed);
}

void EmbedFile(memory_arena *Arena, str8 SourcePath, str8 DestinationPath, str8 Name)
{
	str8_list SourcePaths = {0};
	Str8ListAppend(Arena, &SourcePaths, SourcePath);

	str8_list Names = {0};
	Str8ListAppend(Arena, &Names, Name);

	EmbedFiles(Arena, SourcePaths, DestinationPath, Names);
}

u64 HashSourceFileAndIncludes(memory_arena *Arena, str8 SourceFilename, str8_list IncludePaths, b32 Optimise, compiler Compiler)
{
	str8_list IncludeChainFiles = {0};
	str8_list VisitedFiles = {0};
	FindAllIncludesInFile(Arena, SourceFilename, IncludePaths, &IncludeChainFiles, &VisitedFiles);
	u64 Hash = FNV_HASH_START;
	FNVHash64(&Hash, SourceFilename);
	FNVHash64(&Hash, Str8PushF(Arena, "%d", Compiler));
	FNVHash64(&Hash, Str8PushF(Arena, "%d", Optimise));
	for (str8_list_node *File = IncludeChainFiles.First; File != 0; File = File->Next)
	{
		FNVHash64(&Hash, File->String);
	}

	return Hash;
}

b32 CompileTranslationUnit(memory_arena *Arena, build_options *BuildOptions, str8 SourceFilename, u64 Hash)
{
	str8 HashedFilename = Str8PushF(Arena, "%llu.o", Hash);

	b32 FoundFile = PathExists(Arena, Str8PushF(Arena, "build/%.*s", Str8ToPrintfArgs(HashedFilename)));

	b32 FoundObjectFile = FoundFile;
	if (FoundObjectFile && !BuildOptions->FullRebuild)
	{
		return False;
	}

	b32 FailedToExecute = False;
	b32 FailedToBuild = False;
	str8 CompileCommand = CompileCommandFromBuildOptions(Arena, BuildOptions, HashedFilename, SourceFilename);
	if(ExecuteCommand(Arena, CompileCommand, &FailedToExecute) == False)
	{
		printf(F_ERROR "Failed to launch compiler\n");
		FailedToBuild = True;
	}

	return FailedToBuild || FailedToExecute;
}

b32 LinkObjectFiles(memory_arena *Arena, build_options *BuildOptions, str8_array ObjectFileNames)
{

	str8_array ObjectFilePaths = {0};
	ObjectFilePaths.Count = ObjectFileNames.Count;
	ObjectFilePaths.Items = (str8*)ArenaPush(Arena, ObjectFilePaths.Count*sizeof(str8));

	for (s64 I = 0; I < ObjectFilePaths.Count; I++)
	{
		ObjectFilePaths.Items[I] = Str8PushF(Arena, "%.*s%.*s ",
											 Str8ToPrintfArgs(BuildOptions->OutputPath),
											 Str8ToPrintfArgs(ObjectFileNames.Items[I]));
	}

	str8_list BuildDirectoryEntries = ListOfDirectoryEntriesFromPath(Arena, BuildOptions->OutputPath);
	for(str8_list_node *Entry = BuildDirectoryEntries.First; Entry != Null; Entry = Entry->Next)
	{
		if (Str8EndsWith(Entry->String, Str8(".o")))
		{
			b32 FoundMatch = False;
			str8 FilePathToCheck = Str8PushF(Arena, "%.*s%.*s", Str8ToPrintfArgs(BuildOptions->OutputPath),
																 Str8ToPrintfArgs(Entry->String));
			for (s64 J = 0; J < ObjectFileNames.Count; J++)
			{
				str8 ObjectFilePathWithoutSpace = ObjectFilePaths.Items[J];
				ObjectFilePathWithoutSpace.Size -= 1;
				if (Str8Equal(ObjectFilePathWithoutSpace, FilePathToCheck))
				{
					FoundMatch = True;
					break;
				}
			}
			if (FoundMatch == False)
			{
				DeleteFileFromDisk(Arena, FilePathToCheck);
			}
		}
	}

	str8 LinkCommand = LinkCommandFromBuildOptions(Arena, BuildOptions, ObjectFilePaths);

	b32 FailedToExecute = False;
	b32 FailedToLink = False;
	if(ExecuteCommand(Arena, LinkCommand, &FailedToExecute) == False)
	{
		printf(F_ERROR "Failed to launch linker\n");
		FailedToLink = True;
	}
	return FailedToLink || FailedToExecute;
}

b32 Build(wave_info *WaveInfo, memory_arena *Arena, build_options BuildOptions)
{
	u64 Start = TimeStampNow();

	str8_array RelativeSourceFilePaths = {0};
	str8_array ObjectFileNames = {0};
	if(WaveIsFirstLane(WaveInfo))
	{
		RelativeSourceFilePaths = Str8ArrayFromList(&WaveInfo->Shared->Arena, BuildOptions.SourceFiles);
		ObjectFileNames.Count = RelativeSourceFilePaths.Count;
		ObjectFileNames.Items = (str8*)ArenaPush(&WaveInfo->Shared->Arena, sizeof(str8)*RelativeSourceFilePaths.Count);
	}

	BroadcastToAllLanes(WaveInfo, RelativeSourceFilePaths);
	BroadcastToAllLanes(WaveInfo, ObjectFileNames);

	s64 Count = LaneValueFromTotal(WaveInfo, RelativeSourceFilePaths.Count);
	s64 Index = ExclusiveWavePrefixSum(WaveInfo, Count);

	b32 FailedToBuild = False;
	u64 PerLaneCount = 0;
	for(int I = Index; I < Index + Count; I++)
	{
		PerLaneCount++;
		u64 PerFileStart = TimeStampNow();
		u64 Hash = HashSourceFileAndIncludes(Arena,
											  RelativeSourceFilePaths.Items[I],
											  BuildOptions.IncludePaths,
											  BuildOptions.Optimise,
											  BuildOptions.Compiler);
		b32 FailedToCompile = CompileTranslationUnit(Arena,
							   &BuildOptions,
								RelativeSourceFilePaths.Items[I],
								Hash);
		FailedToBuild |= FailedToCompile;

		ObjectFileNames.Items[I] = Str8PushF(Arena, "%llu.o", Hash);

		if(!FailedToCompile)
		{
			printf("Compiled %.*s in %.2fms\n",
				   Str8ToPrintfArgs(RelativeSourceFilePaths.Items[I]),
				   MilliSecondsFromTimeStamp(TimeStampNow() - PerFileStart));
		}

	}

	b32 AnyFailedToBuild = WaveAnyTrue(WaveInfo, FailedToBuild);

	b32 FailedToLink = False;
	if(WaveIsFirstLane(WaveInfo) && !AnyFailedToBuild)
	{
		printf("\nCompiled all TUs in %.2fms\n", MilliSecondsFromTimeStamp(TimeStampNow() - Start));
		{
			u64 LinkStart = TimeStampNow();

			FailedToLink = LinkObjectFiles(Arena, &BuildOptions, ObjectFileNames);
			printf("Linking finished in %.2fms\n", MilliSecondsFromTimeStamp(TimeStampNow() - LinkStart));
		}
	}

	b32 AnyFailedToLink = WaveAnyTrue(WaveInfo, FailedToLink);

	if(WaveIsFirstLane(WaveInfo) && (AnyFailedToBuild || AnyFailedToLink))
	{
		str8 OutputPathAndName = Str8PushF(Arena, "%.*s/%.*s",
								   Str8ToPrintfArgs(BuildOptions.OutputPath),
								   Str8ToPrintfArgs(BuildOptions.OutputName));
		DeleteFileFromDisk(Arena, OutputPathAndName);

		printf(F_ERROR);
	}
	else if(WaveIsFirstLane(WaveInfo))
	{

		printf(F_SUCCESS);
	}

	return (AnyFailedToBuild || AnyFailedToLink);

}

str8 ForwardSlashPathFromPath(str8 Path)
{
	for(s64 I = 0; I < Path.Size; I++)
	{
		if(Path.Bytes[I] == '\\')
		{
			Path.Bytes[I] = '/';
		}
	}
	return Path;
}

void EmitCompileCommandsJson(memory_arena *Arena, build_options BuildOptions)
{
	str8_list Output = {0};

	Str8ListAppend(Arena, &Output, Str8("[\n"));

	for(str8_list_node *SourceNode = BuildOptions.SourceFiles.First;
		SourceNode != Null;
		SourceNode = SourceNode->Next)
	{
		str8 FileName = ForwardSlashPathFromPath(SourceNode->String);
		str8 ObjectFileName = Str8PushF(Arena, "%.*s.o",
										Str8ToPrintfArgs(
										Str8UpToLastCharacter(Arena,
															  FileName,
															  '.')));
		Str8ListAppend(Arena, &Output, Str8("    {\n"));
		Str8ListAppend(Arena, &Output, Str8PushF(Arena,
			   "        \"directory\": \"%.*s\",\n",
					   Str8ToPrintfArgs(ForwardSlashPathFromPath(BuildOptions.WorkingDirectory))));
		Str8ListAppend(Arena,
				   &Output,
				   Str8PushF(Arena,
				   "        \"command\": \"%.*s\",\n",
				   Str8ToPrintfArgs(CompileCommandFromBuildOptions(Arena,
									&BuildOptions,
									ObjectFileName,
									FileName))));
		Str8ListAppend(Arena,
				 &Output,
			   Str8PushF(Arena,
			   "        \"file\": \"%.*s\"\n",
					   Str8ToPrintfArgs(FileName)));
		Str8ListAppend(Arena, &Output, Str8("    }"));
		if(SourceNode->Next)
		{
			Str8ListAppend(Arena, &Output, Str8(",\n"));
		}
		else
		{
			Str8ListAppend(Arena, &Output, Str8("\n"));
		}
	}

	Str8ListAppend(Arena, &Output, Str8("]\n"));

	WriteStringToDisk(Arena, Str8("compile_commands.json"), Str8ListJoin(Arena, Output));
}
