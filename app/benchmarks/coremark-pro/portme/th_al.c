/* Raptor port, 2026: replaced host timing with RISC-V counters and made
 * al_fsize honor the upstream FAKE_FILEIO option for embedded datasets.
 * All other adaptation code retains the upstream implementation.
 * Upstream revision: 4832cc67b0926c7a80a4b7ce0ce00f4640ea6bec.
 */
/*
(C) 2014 EEMBC(R).  All rights reserved.                            

All EEMBC Benchmark Software are products of EEMBC 
and are provided under the terms of the EEMBC Benchmark License Agreements.  
The EEMBC Benchmark Software are proprietary intellectual properties of EEMBC and its Members 
and is protected under all applicable laws, including all applicable copyright laws.  
If you received this EEMBC Benchmark Software without having 
a currently effective EEMBC Benchmark License Agreement, you must discontinue use. 
Please refer to LICENSE.md for the specific license agreement that pertains to this Benchmark Software.
*/

/*==============================================================================
 * File: mith/al/src/th_al.c
 *
 *  Description: 
 *	Test Harness Adaptation Layer
 *	
 *	Porting:
 *	This is the main file to look at when porting to a new system.
 *	All the functions in this file must be implememnted.
 *	Most common functions to port on embedded board with no OS:
 *	<al_signal_start>
 *	<al_signal_finished>
 *	<al_signal_now>
 *	<al_ticks_per_sec>
 *	<al_tick_granularity>
 *	<al_write_con> and/or <al_printf>
 *	<al_main>
 */

/* ------------------------------------------------------------------------------
 * Other Copyright Notice (if any) : 
 * 
 * For conditions of distribution and use, see the accompanying README file.
 * ===========================================================================*/



#include "th_cfg.h"
#if defined(_MSC_VER)
/* To avoid issues, windows.h must be included before stdXX if used at all */
 #if defined(_DEBUG) && defined(USE_VLD)
  #include "vld.h" /* from http://www.codeproject.com/KB/applications/visualleakdetector.aspx, and copy the dll to al/win32 */
 #endif
 #include <windows.h>
#endif
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
/* since we are using stdio, FILE is defined */
#define FILE_TYPE_DEFINED
#include "th_file.h"
#include "th_types.h"
#include "th_lib.h" /* for th_log */
#include "th_al.h"
#include "al_smp.h"
#if	EE_POWERTAG && HOST_EXAMPLE_CODE && !defined(_MSC_VER)
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
#endif
#if CALLGRIND_RUN
#include <valgrind/callgrind.h>
#endif

#include "counters.h"
static uint64_t start_ticks, start_cycles, start_instructions;
static uint64_t roi_ticks, roi_cycles, roi_instructions;

/**
 * Platform Specific Header Files, Defines, Globals and Local Data
 */

/**
 * Local Defines
 */

/**
 * Local Data
 */

/*
>> Put your platform specific code here
*/
#if 	!HOST_EXAMPLE_CODE
#endif
#if 	EE_POWERTAG

/** Delay in milliseconds to start power measurements. */
#define	POWER_DELAY 	20

/*********************************************************************
Function: Power Functions
<al_power_start> and <al_power_finished> are to sync EnergyBench host.
When the C code hits this function, the target board asserts a trigger. 
Trigger can be either latch-HIGH, latch-LOW, signal-HIGH or signal-LOW.
The LabView scripts have been written to accomodate all above options.  
We need a delay:
1. Due to the response time of the LabView script on the host system itself.
2. If there is some delay from the time trigger_on is called until the time 
   it is detected.

We need a way to assert a pin high or low somewhere on the target
board.  That is what will trigger us to do timing, stop timing, and so
on.  
We also need to be able to connect or soldier probes to measure voltage 
over the resistor as well as load voltage.

Porting:
Reference implementation uses UART (/dev/ttyS0) to signal a trigger.
This implementation was tested with gcc on linux and cygwin.
To accomodate a trigger that does not latch to high, you can set
the voltage level to detect trigger on at HIGH and trigger off at HIGH.
The sampling module will sample from first detection to second detection.

**********************************************************************/


FILE *uio;
char uio_buffer[]="EEMBC";
/* This will issue a signal on ttyS0, which is connected to a UART.
   The DAQ can detect the change in voltage level on the UART, and 
   acquire the trigger to start and stop sampling */

static void uart_trigger_on()
{
	fwrite(uio_buffer,1,1,uio);
	fflush(uio);
}
/* Function: al_power_start
	Description:
	Signal to the host measurement equipment that benchmark started.
	When using energybench, this function is used to provide
	a trigger point, that the host can use to sync benchmark start.
*/
static void al_power_start(void)
{
	
	/** write to ttyS0 */
	uio=fopen("/dev/ttyS0","wr");
	uart_trigger_on();

	/** Wait POWER_DELAY milliseconds. */

	clock_t	
	  start_delay = clock(),
	  stop_delay = start_delay + POWER_DELAY * al_ticks_per_sec()/1000;
	while (stop_delay < clock());

}

/* Function: al_power_finished
	Description:
	Signal to the host measurement equipment that benchmark finished.
	When using energybench, this function is used to provide
	a trigger point, that the host can use to sync benchmark end.
*/
static void al_power_finished(void)
{
	/** PORTING: write to ttyS0 */
	uart_trigger_on();
	fclose(uio);
}
#else
static void al_power_start(void){}
static void al_power_finished(void){}
#endif /* of EE_POWERTAG */

/*------------------------------------------------------------------------------
 *                     >>> TARGET TIMER SUPPORT <<<
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
 * The following five Functions must be modified if you need to support a 
 * timer on your target which will be used to measure benchmark durations.
 *
 * IMPORTANT: You do not have to modify these Functions if you don't want
 *            to support target based timing!  
 * ---------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
 * Function: al_signal_start
 *
 * Description: 
 *			Adaptation layer implementation of th_signal_start()
 *
 *          This Function is called when the benchmark starts.  It should
 *          start the target timer or record the current value of a free
 *          running timer.
 *
 * PORTING: 
 *			If you want to support target based timing, you need to 
 *          fill in this Function.
 * ---------------------------------------------------------------------------*/
#if REPORT_THMALLOC_STATS
extern size_t th_malloc_total;
#endif
void al_signal_start(void)
{
    start_ticks = read_time();
    start_instructions = read_instructions();
    start_cycles = read_cycles();
}

size_t al_signal_finished(void)
{
    roi_cycles = read_cycles() - start_cycles;
    roi_instructions = read_instructions() - start_instructions;
    roi_ticks = read_time() - start_ticks;
    /* MITH uses size_t for ticks: fail rather than wrap on RV32. */
    if (roi_ticks > (size_t)-1) {
        printf("RAPTOR ERROR: timer overflow\n");
        exit(1);
    }
    al_report_results();
    return (size_t)roi_ticks;
}

size_t al_signal_now(void)
{
    return (size_t)(read_time() - start_ticks);
}

size_t al_ticks_per_sec(void) { return CMP_TIMEBASE_HZ; }
size_t al_tick_granularity(void) { return 1; }

/*------------------------------------------------------------------------------
 *                       >>> SUPPORT FunctionS <<<
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - 
 * These support Functions are part of the Adaptaion Layer but do not
 * generally need to be modified.
 * ---------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
 * Function: al_exit
 *                                    
 * Description: 
 *			Exits the benchmark.
 *
 *
 * PARAMS: 
 *			exit_code - the traditional exit code
 *
 *
 * PORTING: 
 *			Standard C in stdlib.h
 * ---------------------------------------------------------------------------*/
   
void al_exit( int exit_code)

{
	al_hardware_reset(exit_code); /* Notify hardware reset that we came from th_exit */
	exit(exit_code);
}

#if	USE_TH_PRINTF
/*------------------------------------------------------------------------------
 * Function: al_write_con
 *
 * Description: 
 *			Sends data to the logical console 
 *
 * PARAMS: 
 *			tx_buf     - a pointer to a buffer containing the data to send
 *          byte_count - the number of bytes from the buffer to send.  If this
 *                       value is zero, then no data is sent to the logical
 *                       console.
 *
 * RETURNS: 
 *			Success if all the characters were sent.
 *          Failure if all the characters could not be sent.  In this case
 *                  some of the characters MAY have been sent.
 *
 * PORTING: 
 *			You will need to fully implement this Function
 * ---------------------------------------------------------------------------*/

int al_write_con( const char* tx_buf, size_t byte_count )

   {
   /* This logic must be preserved */
   if ( byte_count == 0 )
      return Success;

   fwrite( tx_buf, sizeof(char), byte_count, stdout );

   return Success;
   }

#endif

/*------------------------------------------------------------------------------
 * Function: al_printf
 *                                    
 * Description: 
 *			The traditional vprintf, control output from here.
 *
 *
 * PORTING: 
 *			Standard C in stdio.h, and stdargs.h
 *
 * NOTE: 
 *			To convert this to a string, use vsprintf, NOT sprintf.
 * ---------------------------------------------------------------------------*/
int		al_printf(const char *fmt, va_list	args)
{
	return	vprintf(fmt,args);
}

/*-----------------------------------------------------------------------------
 * Function: al_sprintf
 *
 * Description: 
 *			The traditional vsprintf, control output from here.
 *
 *
 * PORTING: 
 *			Standard C in stdio.h, and stdargs.h
 *
 * NOTE: 
 *			To convert this to a string, use vsprintf, NOT sprintf.
 * ---------------------------------------------------------------------------*/
int     al_sprintf(char *str, const char *fmt, va_list   args)
{
	return  vsprintf(str,fmt,args);
}

/*------------------------------------------------------------------------------
 * Function: al_report_results
 *                                    
 * Description: 
 *			Print additional messages below harness output.
 *
 * PORTING: 
 *			Use harness th_printf.
 * ---------------------------------------------------------------------------*/
void	al_report_results( void )
{
    printf("Raptor benchmark run: iterations=%u verify=%u timebase=%u Hz\n",
           CMP_ITERATIONS, CMP_VERIFY, CMP_TIMEBASE_HZ);
    printf("Internal workload measurement; no certified aggregate score.\n");
    printf("RAPTOR ROI cycles=%llu instructions=%llu ticks=%llu\n",
           (unsigned long long)roi_cycles,
           (unsigned long long)roi_instructions,
           (unsigned long long)roi_ticks);
}

/* scanf input format conversion family <stdargs.h> */

/** Function: al_vsscanf
 Simple vsscanf implementation, using scanf 

*/
int	al_vsscanf(const char *str, const char *format, va_list ap)
{
#if 	USE_TH_FILEIO || !HAVE_VSSCANF
#define VSSF_MAX 7
	/* simple implementation of up to 7 args using sscanf */
  void      *arg[VSSF_MAX];
  /* first find out how many args there are from fmt? */
  int numargs=0,i;
  const char *pfind=format;
  while (*pfind) {
	  if (pfind[0]=='%') {
		  if (pfind[1]=='*' || pfind[1]=='%') 
			  pfind++; /* ignore %* and %% */
		  else
			  numargs++; /*otherwise there should be another arg */
	  }
	  pfind++;
  }
  if (numargs>VSSF_MAX) {
	  th_log(TH_ERROR,"ERROR: too many args to vsscanf");
	  return 0; /* error here */
  }
  /* copy the args to a local array to make sure we are thread safe */
  {
    for ( i=0; i<numargs; i++ )
      arg[i] = va_arg( ap, void * );
  }
  /* then call sscanf */
  switch (numargs) {
	  case 1: return sscanf(str,format,arg[0]);
	  case 2: return sscanf(str,format,arg[0],arg[1]);
	  case 3: return sscanf(str,format,arg[0],arg[1],arg[2]);
	  case 4: return sscanf(str,format,arg[0],arg[1],arg[2],arg[3]);
	  case 5: return sscanf(str,format,arg[0],arg[1],arg[2],arg[3],arg[4]);
	  case 6: return sscanf(str,format,arg[0],arg[1],arg[2],arg[3],arg[4],arg[5]);
	  case 7: return sscanf(str,format,arg[0],arg[1],arg[2],arg[3],arg[4],arg[5],arg[6]);
	  default: return 0;
  }
#elif	HAVE_FILEIO || HAVE_VSSCANF
	return vsscanf(str,format,ap);
#else
	return NULL;
#endif
}

/** Function: al_vsscanf
 Simple vsscanf implementation, using scanf 

*/
int	al_vfscanf(ee_FILE *stream, const char *format, va_list ap)
{
#if 	USE_TH_FILEIO || !HAVE_VFSCANF
 #if FAKE_FILEIO 
 #warning "No implementation for vfscanf, please make sure no workloads are using this function or provide an implementation for the adaptation layer"
 return NULL;
 #endif
 #define VSSF_MAX 7
	/* simple implementation of up to 7 args using fscanf */
  void      *arg[VSSF_MAX];
  /* first find out how many args there are from fmt? */
  int numargs=0,i;
  const char *pfind=format;
  while (*pfind) {
	  if (pfind[0]=='%') {
		  if (pfind[1]=='*' || pfind[1]=='%') 
			  pfind++; /* ignore %* and %% */
		  else
			  numargs++; /*otherwise there should be another arg */
	  }
	  pfind++;
  }
  if (numargs>VSSF_MAX) {
	  th_log(TH_ERROR,"ERROR: too many args to vfscanf");
	  return 0; /* error here */
  }
  /* copy the args to a local array to make sure we are thread safe */
  {
    for ( i=0; i<numargs; i++ )
      arg[i] = va_arg( ap, void * );
  }
  /* then call sscanf */
  switch (numargs) {
	  case 1: return fscanf(stream,format,arg[0]);
	  case 2: return fscanf(stream,format,arg[0],arg[1]);
	  case 3: return fscanf(stream,format,arg[0],arg[1],arg[2]);
	  case 4: return fscanf(stream,format,arg[0],arg[1],arg[2],arg[3]);
	  case 5: return fscanf(stream,format,arg[0],arg[1],arg[2],arg[3],arg[4]);
	  case 6: return fscanf(stream,format,arg[0],arg[1],arg[2],arg[3],arg[4],arg[5]);
	  case 7: return fscanf(stream,format,arg[0],arg[1],arg[2],arg[3],arg[4],arg[5],arg[6]);
	  default: return 0;
  }
#elif	HAVE_FILEIO
	return vfscanf(stream,format,ap);
#else
	return NULL;
#endif
}

/* NON Standard routines */
/* Function: al_filecmp
	Compare two files.

	Note:
		Not supported in initial version of MITH
*/
int	al_filecmp (const char *file1, const char *file2) 
{
#if	USE_TH_FILEIO
	return file1==file2; /* not implemented */
#elif	HAVE_FILEIO
	return file1==file2; /* not implemented */
#else
	return file1==file2;
#endif
}
/* Function: al_fcreate
	create a file with predefined content 
*/
void	*al_fcreate(const char *filename, const char *mode, char *data, size_t size) {
	ee_FILE *f;
	/* A writable file - just create */
	if (strchr(mode, 'w') || size==0)
		return th_fopen(filename,mode);
	/* Otherwise, create a new file with data, and then open it */
	f=th_fopen(filename,"w");
	th_fwrite(data,size,1,f);
	th_fclose(f);
	return th_fopen(filename,mode);
}


/** Function: al_fsize
	Non Standard routine to return file size.

Note:
	If the toolchain has the stat Function, a POSIX standard
	way is available to return file size.
 */
size_t	al_fsize(const char *filename)
{
#if FAKE_FILEIO || USE_TH_FILEIO
	return 0; /* not implemented */
#elif	HAVE_STAT_H || HAVE_SYS_STAT_H
/** Get file size using stat Function */
    size_t	length;
    struct	stat st;

    if (!filename || !*filename) 
		length=0;
	else {
        if ((stat(filename,&st))==-1)
			length=0;
        else
			length = st.st_size;
	}
    return length;
#elif	HAVE_FILEIO
	size_t total;
	FILE *fp=fopen(filename, "rb");
	if (fp==NULL) return 0;
	fseek(fp, 0, SEEK_END);
	total=ftell(fp);
	fclose(fp);
	return total;
#else
	th_log(0,"ERROR: fsize called but no implementation");
	return 0;
#endif
}

/** Function: al_getenv
Get Environment Variable (libc) 

This routine is used for host based benchmark which use
environment variables. You can set up pre-defined environment
variables here, or return NULL for not found.
Params:
	key - Environment variable name
Returns:
	Environment variable value, or NULL if not found.
*/
char	*al_getenv( const char *key )
{
#if	HOST_EXAMPLE_CODE
	return getenv(key);
#else
	return NULL;
#endif
}


/*------------------------------------------------------------------------------
 * Function: al_main
 *                                    
 * Description: 
 *			Target Specific Initialization for all Benchmarks
 *
 * PORTING: 
 *			Use bmark_lite.c: main for benchmark specific init..
 * ---------------------------------------------------------------------------*/

void redirect_std_files(void);
void	al_main( int argc, char* argv[]  )
{
	argc=argc; /*avoid compiler warning */
	argv=argv; /*avoid compiler warning */
	redirect_std_files();

	/*
	> Perform target specific command line processing here.
	> Many systems will not need to put anything in this section. However,
	> special command line options may make porting your benchmarks easier.
	*/

#if 	!HOST_EXAMPLE_CODE
#endif
   
	/*- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	* AL_SECTION_1
	*/

	/*
	> Perform target specific initialization here.  This should be really
	> low level code.  Many systems will not need to put anything in this
	> section.  However, your HW may require some initialization before
	> the logical console I/O channel opened.  That kind of stuff goes here.
	*/
#if 	!HOST_EXAMPLE_CODE
#endif

   /*- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    * AL_SECTION_2
    *
    * Open the logical console I/O channel. This should be done as soon
    * as possible in the initialization process.  Error messages cannot
    * be sent to the logical console until this call is made.
	*/

#if 	!HOST_EXAMPLE_CODE
#endif

   /*- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    * AL_SECTION_3
   */

   /*
   >> Most of the system initialization code should go here.
   */
#if 	!HOST_EXAMPLE_CODE
#endif
#if THDEBUG
	th_log(TH_INFO,"Finished target initialization.");
#endif

}

/* Function: al_hardware_reset
 * Description:
 *			This is the last step called by main in all the benchmarks.
 *
 * NOTE: 
 *			ev from th_exit is passed, or 0 if not from an exit.
 */

void al_hardware_reset(int ev)
{
   /*- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    * AL_SECTION_7
    */

   /*
   >> Here is where you can do any last cleanup that needs to happen
   >> after you close the Logical Console I/O channel.
   */
	if (ev == 0)
	{
		/* Normal Termination */
#if 	!HOST_EXAMPLE_CODE
#endif
	} else
	{
		/* Terminate has occurred from th_exit */
#if 	!HOST_EXAMPLE_CODE
#endif
	}
}

#if (FP_KERNELS_SUPPORT)
#if    HOST_EXAMPLE_CODE
#include "fp_shape.h"

int store_dp(e_f64 *value, intparts *asint)
{
   e_f64 v64;
   e_u32 iexp;
   e_s32 exp=asint->exp;
   e_u32 manthigh=asint->mant_high32;

   if (manthigh >= ((e_u32)1<<(52-32 + 1)))
   {
      return 0;
   }
   if (!(manthigh & ((e_u32)1<<(52-32))))
   {
      /* special casing signed zero */
      if (exp ==0 && asint->mant_low32 == 0 && manthigh == 0)
      {
		INSERT_WORDS(v64, (e_u32)(asint->sign) << 31, 0);
        *value = v64;
        return 1;
      }
      return 0;
   }

   manthigh &= ((e_u32)1 << (52-32)) - 1;

   exp += 1023;
   if (exp <= 0 || exp >= 2047)
   {
      return 0;
   }
   iexp = exp << (52-32);
   if (asint->sign)
   {
      iexp |= 0x80000000;
   }
   INSERT_WORDS(v64, (manthigh | iexp), asint->mant_low32);
   *value = v64;
   return 1;
}

/* supports denorm, no inf/nan */
int load_dp(e_f64 *value, intparts *asint)
{
   e_u32 iValue0, iValue1;

   if (!value || !asint)
      return 0;

   EXTRACT_WORDS(iValue1, iValue0, *value);

   asint->mant_low32 = iValue0;
   asint->mant_high32 = (iValue1 & (((e_u32)1 << (52 - 32)) - 1));
   asint->exp = ((iValue1 >> (52-32)) & 2047);
   asint->sign = iValue1 >> 31;

   if (asint->exp == 2047)
      return 0;

   if (asint->exp != 0)
   {
      asint->mant_high32 |=  ((e_u32)1 << (52-32));
      asint->exp -= 1023;
   }
   else
   {
      if (asint->mant_high32 || asint->mant_low32)
         return 0;
   }
   return 1;
}

/* no denormal/inf/nan support */
int store_sp(e_f32 *value, intparts *asint)
{
   e_u32 iValue;
   e_f32 v32;
   e_u32 iexp;
   e_s32 exp=asint->exp;
   e_u32 mant=asint->mant_low32;

   if (asint->mant_high32)
      return 0;

   if (mant >= ((e_u32)1<<24))
   {
      return 0;
   }
   if (!(mant & ((e_u32)1<<23)))
   {
      /* special casing signed zero */
      if (exp == 0 && mant == 0)
      {
         iValue = (e_u32)(asint->sign) << 31;
         SET_FLOAT_WORD(v32, iValue);
         *value = v32;
         return 1;
      }
      return 0;
   }

   mant &= ((e_u32)1 << 23) - 1;

   exp += 127;
   if (exp <= 0 || exp >= 255)
   {
      return 0;
   }
   iexp = exp << 23;
   if (asint->sign)
   {
      iexp |= 0x80000000;
   }
   iValue = mant | iexp; 
   SET_FLOAT_WORD(v32, iValue);
   *value = v32;
   return 1;
}

int load_sp(e_f32 *value, intparts *asint)
{
   e_u32 iValue;

   if (!value || !asint)
      return 0;

   GET_FLOAT_WORD(iValue, *value);

   asint->mant_high32 = 0;
   asint->mant_low32 = (iValue & (((e_u32)1 << 23) - 1));
   asint->exp = ((iValue >> 23) & 255);

   if (asint->exp == 255)
      return 0;

   if (asint->exp != 0)
   {
      asint->mant_low32 |=  ((e_u32)1 << 23);
      asint->exp -= 127;
   }
   else
   {
      if (asint->mant_low32)
         return 0;
   }
   asint->sign = iValue >> 31;
   return 1;
}

#else /* !HOST_EXAMPLE_CODE */
int store_dp(e_f64 *value, intparts *asint) {
#error "Must define a method to create a floating point number from integer parts."
}
int load_dp(e_f64 *value, intparts *asint) {
#error "Must define a method to decode a floating point number to integer parts."
}
int store_sp(e_f32 *value, intparts *asint) {
#error "Must define a method to create a floating point number from integer parts."
}
int load_sp(e_f32 *value, intparts *asint) {
#error "Must define a method to decode a floating point number to integer parts."
}
#endif /* of !HOST_EXAMPLE_CODE */

#if AL_ISFINITE
 int al_isfinite_dp(e_f64 x){
#error "Please provide your own implementation of a function that returns true for non-denormal, non-infinite numbers, and false otherwise."
}
 int al_isfinite_sp(e_f32 x){
#error "Please provide your own implementation of a function that returns true for non-denormal, non-infinite numbers, and false otherwise."
}
#endif

#endif /* Of using floating point kernels */
