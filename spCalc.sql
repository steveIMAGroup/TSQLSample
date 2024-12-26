/****** Object:  StoredProcedure [dbo].[spCalc]    Script Date: 11/27/2024 8:47:34 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[spCalc]
	(@criStartDate DATETIME,
	@criStopDate DATETIME,
	@criOption TINYINT = 1,
	@criDebug BIT = 0,
	@criFamilyID INT = 0,
	@criChildID INT = 0,
	@criProgramID INT = 0,
	@criScheduleID INT = 0,
	@criProviderID INT = 0,
	@criSpecialistID INT = 0,
	@criDivisionID INT = 0,
	@criUserID INT = 0,
	@criUseAttendance BIT = 0,
	@criIncludeAttendance TINYINT = 2,
	@criProgramGroupID INT = 0,
	@criVariable TINYINT = 0)
AS

SET NOCOUNT ON

/* Procedure summary */
--Based on which option is sent by the application, calculate provider payment,
--projection, or family fee data for the specified criteria.  Insert the results
--into the appropriate result table.

--Author: Steven R.

/* @criOption settings */
--1: Time sheet/provider payment
--2: Projection
--3: Family fee
--4: Family fee adjustment

/* Projection error codes */
--F:	Family First Served Date
--C:	Family Cert Start Date
--C:	Family Cert Stop Date
--T:	Family Term Date
--W:	Family CalWorks Stop Date
--W:	Family Ineligibility Date
--E:	Child Enrolled Date
--T:	Child Term Date
--LOA:	Child LOA Date
--PVSV:	Provider Service Start Date
--PVSV:	Provider Service Stop Date
--PVD:	Provider Denied
--PGS:	Program Start Date
--TX:	Program Stop Date
--MA:	Program Max Age
--FEE:	Fixed Fee

/* Procedure steps */
--1.	Split the original date range entered into months.  Only one month will be
--		calculated at a time.  Partial months can be calculated.  For instance, if a
--		calculation is run for November 16th through December 24th, the procedure will
--		first calculate for	November 16th through November 30th, then for December 1st
--		through December 24th.
--2.	Delete all data meeting the criteria passed to the procedure.
--3.	Pull all the schedules meeting the specified criteria, based
--		on setup options chosen by each agency.
--		a.	If family fees are being calculated, either as the entire calculation or
--			as a deduction in the time sheet/provider payment calculation, generate
--			a list of the families being calculated and pull all schedules for the date
--			range for those families, even if only certain children meet the original
--			criteria, and insert the schedules into a temp table.
--		b.	If family fees are not being calculated, insert only the schedules meeting
--			the original criteria into a temp table.
--4.	If the schedule start date and/or stop date fall outside of the current date range
--		being calculated, set the date or dates to the current date range.
--5.	Modify the schedule start and stop dates in the temp table based on the various
--		dates entered for the families, children and providers.  If projections are being
--		calculated, insert projection error codes for each date change.  Delete all
--		schedules which do not cover a valid date range (the start date is after the stop
--		date).
--6.	The remaining schedules are cross joined with a daily calendar table to produce
--		a Cartesian product showing each day for each schedule.  Only days with valid
--		programs (meaning the child has a program assigned for this date and is not over
--		the max age limit) are included.  If the provider does not charge for absences and
--		the child is absent, that day is excluded (except in projection calculation).
--7.	All vacation days are flagged, based on the school district and school track
--		vacation schedules.  Holidays were already marked in the original calendar table.
--8.	Determine the rate type for each day based on either the regular or vacation
--		schedule, whichever is appropriate.
--9.	Determine whether the schedule is full-time or part-time for each day, based on
--		the rate type.
--10.	Set the rate for each day, based on whether the schedule is regular/vacation and
--		full-time/part-time.
--11.	Update rates from the provider rate book if the schedule is using the rate book.
--12.	If family fees are being calculated, set the fee rates for each day for each child
--		based on whether 6 or more hours of care are scheduled total (across all providers
--		and schedules).  Less than 6 hours: part-time rate.  6 or more hours: full-time
--		rate.
--13.	Insert results into output table for the appropriate option.
--		a.	For time sheet (provider payment) and projection, a separate INSERT
--			statement is run for each rate type.  Hourly and daily results exclude 
--			days with no care (hours scheduled = 0).  Weekly results exclude weekends.
--			Monthly results include each day that the schedule is in effect (active),
--			regardless of whether care is scheduled for that day.  Fixed fees are also
--			included.--		b.	For family fee, one INSERT statement is run, as all fees are daily.  The family
--			fee deduction is also included for time sheet/provider payment if the option is set.
--14.	If the original ending date for the calculation has not been reached, go to the
--		next month and perform steps 2 through 14.
--15.	If family fees were calculated, determine the billing child for each family.  This
--		is the youngest of the children with the highest total fee for each family.  Delete
--		all non-billing child fee data.
--16.	For time sheet/provider payment and family fee, delete all data that does not match
--		the original criteria entered.

/* Create temp tables */
--Full-time cutoff hours
CREATE TABLE #tmpFTCutoff
	(ProgramID INT NOT NULL,
	RateTypeCode VARCHAR (2) NOT NULL,
	EffectiveDate DATETIME NOT NULL,
	FTCutoffTypeProviderPayment TINYINT NULL,
	PTCutoffProviderPayment NUMERIC (6, 4) NULL,
	FTCutoffProviderPayment NUMERIC (6, 4) NULL,
	FTCutoffTypeFamilyFee TINYINT NULL,
	PTCutoffFamilyFee NUMERIC (6, 4) NULL,
	FTCutoffFamilyFee NUMERIC (6, 4) NULL)

--Calendar temp table
CREATE TABLE #tmpCalendar
	(CalendarDate DATETIME NOT NULL,
	DayOfWeek TINYINT NOT NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL)

--Family list
--Used only if family fees will be calculated
CREATE TABLE #tmpFamilyList
	(FamilyID INT NOT NULL)

--Family list 
--Used only if family fee Adjustments will be calculated
CREATE TABLE #tmpFamilyAdjustmentList
	(FamilyID INT NOT NULL)

--Family list 
--Used only if family fee Adjustments will be calculated
CREATE TABLE #tmpFamilyBilledList
	(FamilyID INT NOT NULL)

--Schedule
CREATE TABLE #tmpScheduleCopyInitial
	(ScheduleID INT NOT NULL,
	ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	ClassroomID INT NULL,
	FamilyID INT NOT NULL,
	ExtendedSchedule BIT NOT NULL DEFAULT (0),
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	SiblingDiscount BIT NOT NULL,
	WeeklyHoursRegular NUMERIC (5, 2) NULL,
	WeeklyHoursVacation NUMERIC (5, 2) NULL,
	PrimaryProvider BIT NOT NULL,
	PayFamily BIT NOT NULL,
	SpecialNeedsRMRMultiplier BIT NOT NULL DEFAULT(0),
	FamilyFirstServedDate DATETIME NULL,
	FamilyCertStartDate DATETIME NULL,
	FamilyCertStopDate DATETIME NULL,
	FamilyTermDate DATETIME NULL,
	FamilyCalWorksCashAidTermDate DATETIME NULL,
	FamilyCalWorksIneligibilityDate DATETIME NULL,
	FamilyCalWorksStage1StartDate DATETIME NULL,
	FamilyCalWorksStage1StopDate DATETIME NULL,
	FamilyCalWorksStage2StartDate DATETIME NULL,
	FamilyCalWorksStage2StopDate DATETIME NULL,
	FamilyCalWorksStage3StartDate DATETIME NULL,
	FamilyCalWorksStage3StopDate DATETIME NULL,
	ChildFirstEnrolled DATETIME NULL,
	ChildTermDate DATETIME NULL,
	ProviderServiceStartDate DATETIME NULL,
	ProviderServiceStopDate DATETIME NULL,
	ProviderDenied BIT NOT NULL DEFAULT (0),
	ProviderDenialDate DATETIME NULL)

CREATE TABLE #tmpAttendanceCopyInitial
	(ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	ClassroomID INT NULL,
	ProgramID INT NULL,
	FamilyID INT NOT NULL,
	AttendanceDate DATETIME NULL,
	AttendanceHours NUMERIC (5, 2) NULL,
	DayOfWeek TINYINT NOT NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	TrueWeekStart DATETIME NULL,
	TrueWeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL,
	WeeklyHoursRegular NUMERIC (5, 2) NULL)

CREATE TABLE #tmpScheduleCopy
	(ScheduleID INT NOT NULL,
	ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	ClassroomID INT NULL,
	FamilyID INT NOT NULL,
	ExtendedSchedule BIT NOT NULL DEFAULT (0),
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	SiblingDiscount BIT NOT NULL,
	WeeklyHoursRegular NUMERIC (5, 2) NULL,
	WeeklyHoursVacation NUMERIC (5, 2) NULL,
	PrimaryProvider BIT NOT NULL,
	PayFamily BIT NOT NULL,
	SpecialNeedsRMRMultiplier BIT NOT NULL DEFAULT(0),
	FamilyFirstServedDate DATETIME NULL,
	FamilyCertStartDate DATETIME NULL,
	FamilyCertStopDate DATETIME NULL,
	FamilyTermDate DATETIME NULL,
	FamilyCalWorksCashAidTermDate DATETIME NULL,
	FamilyCalWorksIneligibilityDate DATETIME NULL,
	FamilyCalWorksStage1StartDate DATETIME NULL,
	FamilyCalWorksStage1StopDate DATETIME NULL,
	FamilyCalWorksStage2StartDate DATETIME NULL,
	FamilyCalWorksStage2StopDate DATETIME NULL,
	FamilyCalWorksStage3StartDate DATETIME NULL,
	FamilyCalWorksStage3StopDate DATETIME NULL,
	ChildFirstEnrolled DATETIME NULL,
	ChildTermDate DATETIME NULL,
	ProviderServiceStartDate DATETIME NULL,
	ProviderServiceStopDate DATETIME NULL,
	ProviderDenied BIT NOT NULL DEFAULT (0),
	ProviderDenialDate DATETIME NULL)

CREATE TABLE #tmpAttendanceCopy
	(ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	ClassroomID INT NULL,
	ProgramID INT NULL,
	FamilyID INT NOT NULL,
	AttendanceDate DATETIME NULL,
	AttendanceHours NUMERIC (5, 2) NULL,
	DayOfWeek TINYINT NOT NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	TrueWeekStart DATETIME NULL,
	TrueWeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL,
	WeeklyHoursRegular NUMERIC (5, 2) NULL)

CREATE TABLE #tmpBilledFees
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ProgramID INT NOT NULL,
 	InvoiceID INT NOT NULL,
 	ProviderID INT NOT NULL,
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	PaymentTypeID INT NULL,
	RateTypeID INT NULL,
	CareTimeID INT NULL,	 
	Rate MONEY NULL,
	Units NUMERIC (5, 2) NULL,
	Total MONEY NULL,
	UserID INT NULL,
	AttendancePaymentTypeID INT NULL,
	AttendanceRateTypeID INT NULL,
	AttendanceCareTimeID INT NULL,	 
	AttendanceRate MONEY NULL,
	AttendanceUnits NUMERIC (5, 2) NULL,
	AttendanceTotal MONEY NULL,
	AdjustmentTotal MONEY NULL,
	AttendanceProgramID INT NULL)

CREATE TABLE #tmpBilledFeesCopy
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ProgramID INT NOT NULL,
 	InvoiceID INT NOT NULL,
 	ProviderID INT NOT NULL,
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	PaymentTypeID INT NULL,
	RateTypeID INT NULL,
	CareTimeID INT NULL,	 
	Rate MONEY NULL,
	Units NUMERIC (5, 2) NULL,
	Total MONEY NULL,
	UserID INT NULL,
	AttendancePaymentTypeID INT NULL,
	AttendanceRateTypeID INT NULL,
	AttendanceCareTimeID INT NULL,	 
	AttendanceRate MONEY NULL,
	AttendanceUnits NUMERIC (5, 2) NULL,
	AttendanceTotal MONEY NULL,
	AdjustmentTotal MONEY NULL,
	AttendanceProgramID INT NULL)

--Most recent schedule for each child/provider combo
CREATE TABLE #tmpLatestStopDate
	(ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	StopDate DATETIME NOT NULL)

--Day-by-day schedule
CREATE TABLE #tmpScheduleDayByDay
	(ScheduleID INT NOT NULL,
	ExtendedSchedule BIT NOT NULL DEFAULT (0),
	FirstDayOfScheduledCare DATETIME NULL,
	LastDayOfScheduledCare DATETIME NULL,
	CalendarDate DATETIME NOT NULL,
	DayOfWeek TINYINT NOT NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL,
	PaymentTypeCode VARCHAR (2) NULL)

--Schedule detail
CREATE TABLE #tmpScheduleDetail
	(ScheduleDetailID INT NOT NULL,
	ScheduleID INT NOT NULL,
	PaymentTypeCode VARCHAR (2) NULL,
	Hours NUMERIC (4, 2) NULL,
	--Hours per week for this detail entry
	WeeklyHours NUMERIC (5, 2) NULL,
	--Total weekly hours for all detail entries of this rate type
	HoursPerWeek NUMERIC (5, 2) NULL,
	Evening BIT NOT NULL DEFAULT (0),
	Weekend BIT NOT NULL DEFAULT (0),
	FixedFee BIT NOT NULL DEFAULT (0),
	RateTypeID TINYINT NULL,
	FullTimeRate MONEY NULL,
	PartTimeRate MONEY NULL,
	FullFeeRate MONEY NULL,
	RateBookDetailID INT NULL,
	FullFeeRateBookDetailID INT NULL,
	ProgramID INT NULL,
	Breakfast BIT NOT NULL DEFAULT (0),
	Lunch BIT NOT NULL DEFAULT (0),
	Snack BIT NOT NULL DEFAULT (0),
	Dinner BIT NOT NULL DEFAULT (0))
	
--Assignment of a single program per schedule if program
--is not found in fixed fee record
--Used for Fixed Fes
CREATE TABLE #tmpScheduleProgram
	(ScheduleID INT NOT NULL,
	ProgramID INT NOT NULL)
	
--Schedule detail days
CREATE TABLE #tmpScheduleDetailDay
	(ScheduleDetailID INT NOT NULL,
	DayID INT NOT NULL,
	HoursPerDay NUMERIC (5, 2) NULL)

--Attendance data
CREATE TABLE #tmpAttendanceDetail
	(AttendanceDate DATETIME NOT NULL,
	ChildID INT NOT NULL,
	ProviderID INT NOT NULL,
	ScheduleDetailID INT NULL,
	ProgramID INT NULL,
	Hours NUMERIC (5, 2) NULL,
	HoursPerDay NUMERIC (5, 2) NULL,
	HoursPerWeek NUMERIC (5, 2) NULL,
	RateTypeID INT NULL,
	FullTimeRate MONEY NULL,
	PartTimeRate MONEY NULL,
	Pay BIT NOT NULL DEFAULT (0))

--Day-by-day schedule detail
CREATE TABLE #tmpDayByDay
	(ScheduleID INT NOT NULL,
	ScheduleDetailID INT NOT NULL,
	ExtendedSchedule BIT NOT NULL,
	CalendarDate DATETIME NOT NULL,
	DayOfWeek TINYINT NOT NULL,
	WeekNumber TINYINT NULL,
	WeeksInMonth TINYINT NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	BookendWeek BIT NOT NULL DEFAULT (0),
	TrueWeekStart DATETIME NULL,
	TrueWeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL,
	PayChargeForDay BIT NOT NULL DEFAULT (1),
	DaysPerWeek NUMERIC (3, 2) NULL,
	DaysPerWeekFamilyFee NUMERIC (3, 2) NULL,
	ActualDaysPerWeek TINYINT NULL,
	DaysPerMonth NUMERIC (4, 2) NULL,
	DaysPerMonthFamilyFee NUMERIC (4, 2) NULL,
	ProgramID INT NULL,
	Hours NUMERIC (4, 2) NULL,
	HoursPerDay NUMERIC (5, 2) NULL,
	HoursPerWeek NUMERIC (5, 2) NULL,
	ActualHoursPerDay NUMERIC (5, 2) NULL,
	ActualHoursPerWeek NUMERIC (5, 2) NULL,
	AverageHoursPerWeek NUMERIC (6, 2) NULL,
	CareEachWeek BIT NOT NULL DEFAULT (1),
	Evening BIT NOT NULL DEFAULT (0),
	Weekend BIT NOT NULL DEFAULT (0),
	PaymentTypeID TINYINT NULL,
	CareTimeID TINYINT NULL,
	RateTypeID TINYINT NULL,
	Rate MONEY NULL,
	AttendanceRateTypeID INT NULL,
	AttendanceFullTimeRate MONEY NULL,
	AttendancePartTimeRate MONEY NULL,
	RateBookDetailID INT NULL,
	RateBookRateTypeID INT NULL,
	RateBookCareTimeID INT NULL,
	FullFeeRateBookDetailID INT NULL,
	Breakfast BIT NOT NULL DEFAULT (0),
	Lunch BIT NOT NULL DEFAULT (0),
	Snack BIT NOT NULL DEFAULT (0),
	Dinner BIT NOT NULL DEFAULT (0))

--List of families paid directly (excluded from family fee)
CREATE TABLE #tmpPayFamily
	(FamilyID INT NOT NULL)

--Family fee rates
CREATE TABLE #tmpFeeRates
	(FamilyID INT NOT NULL,
	EffectiveDate DATETIME NULL,
	FullTimeFee MONEY NULL,
	PartTimeFee MONEY NULL)

--Family fee
CREATE TABLE #tmpFamilyFee
	(ChildID INT NOT NULL,
	ProgramID INT NOT NULL,
	ScheduleID INT NULL,
	ScheduleDetailID INT NULL,
	ProviderID INT NULL,
	CalendarDate DATETIME NOT NULL,
	DayOfWeek TINYINT NULL,
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	WeekStart DATETIME NULL,
	WeekStop DATETIME NULL,
	MonthStart DATETIME NULL,
	MonthStop DATETIME NULL,
	EffectiveDate DATETIME NULL,
	Hours NUMERIC (4, 2) NULL,
	HoursPerDay NUMERIC (4, 2) NULL,
	HoursPerWeek NUMERIC (5, 2) NULL,
	DaysPerWeek INT NULL,
	DaysPerMonth INT NULL,
	RateTypeID INT NULL,
	Rate MONEY NULL,
	CareTimeID TINYINT NULL)

--Rate book storage by day
CREATE TABLE #tmpRateBookByDay
	(ScheduleDetailID INT NOT NULL,
	RateBookDetailID INT NOT NULL,
	CalendarDate DATETIME NOT NULL,
	StartDate DATETIME NOT NULL,
	StopDate DATETIME NOT NULL,
	RateTypeID TINYINT NULL,
	PartTimeRate SMALLMONEY NULL,
	FullTimeRate SMALLMONEY NULL)

--Full fee rate book storage by day
CREATE TABLE #tmpFullFeeRateBookByDay
	(ScheduleDetailID INT NOT NULL,
	FullFeeRateBookDetailID INT NOT NULL,
	CalendarDate DATETIME NOT NULL,
	StartDate DATETIME NOT NULL,
	StopDate DATETIME NOT NULL,
	RateTypeID INT NULL,
	FullFeeRate SMALLMONEY NULL)

--Fee totals by child
CREATE TABLE #tmpFamilyFeeTotal
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ServiceDate DATETIME NULL,
	Total MONEY NULL)
	
--Billing child by family
CREATE TABLE #tmpFamilyMaxFee
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ServiceDate DATETIME NULL,)

--Projection error
CREATE TABLE #tmpError
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ProgramID INT NOT NULL,
	ScheduleID INT NOT NULL,
	ProviderID INT NOT NULL,
	ErrorDate DATETIME NOT NULL,
	ErrorCode CHAR (3) NOT NULL,
	ErrorDesc VARCHAR (255) NULL)

--RMR validation tables
CREATE TABLE #tmpScheduleEveningWeekend
	(ScheduleID INT NOT NULL,
	ChildID INT NOT NULL,
	BirthDate DATETIME NULL,
	SpecialNeedsRMRMultiplier BIT NOT NULL DEFAULT(0),
	ChildAge NUMERIC (5, 2) NULL,
	ProviderID INT NOT NULL,
	StartDate DATETIME NULL,
	StopDate DATETIME NULL,
	ScheduleEffectiveDate DATETIME NOT NULL,
	CalendarDate DATETIME NULL,
	PaymentTypeCode VARCHAR(2) NULL,
	WeeklyHours NUMERIC (5, 2) NULL,
	WeeklyHoursRegular NUMERIC (5, 2) NULL,
	WeeklyHoursVacation NUMERIC (5, 2) NULL,
	EveningWeekendPercent NUMERIC (5, 4) NULL DEFAULT (0),
	SpecialNeeds BIT NOT NULL DEFAULT (0),
	Weekend BIT NOT NULL DEFAULT (0),
	Evening BIT NOT NULL DEFAULT (0),
	ExceptionalNeeds BIT NOT NULL DEFAULT (0),
	SeverelyHandicapped BIT NOT NULL DEFAULT (0))

CREATE TABLE #tmpScheduleDetailRMR
	(ScheduleDetailID INT NOT NULL,
	ScheduleID INT NOT NULL,
	ProviderTypeID INT NULL,
	PaymentTypeID INT NOT NULL,
	StartTime DATETIME NULL,
	StopTime DATETIME NULL,
	Hours NUMERIC (5, 2) NULL,
	WeeklyHours NUMERIC (5, 2) NULL,
	RateTypeID INT NULL,
	CareTimeCode VARCHAR (2) NOT NULL,
	Rate MONEY NULL,
	RMRDescriptionID INT NULL,
	ScheduleEffectiveDate DATETIME NULL,
	RMREffectiveDate DATETIME NULL,
	MultiplierEffectiveDate DATETIME NULL,
	RMRMultiplier NUMERIC (4, 3) NOT NULL DEFAULT (1),
	BaseRMR MONEY NULL,
	MarketRate MONEY NULL,
	AboveRMR BIT NOT NULL DEFAULT (0))

--Calculation result
CREATE TABLE #tmpResult
	(FamilyID INT NOT NULL,
	ChildID INT NOT NULL,
	ChildAge NUMERIC (5, 2) NULL,
	ProgramID INT NULL,
	ScheduleID INT NULL,
	ScheduleDetailID INT NULL,
	ExtendedSchedule BIT NOT NULL DEFAULT (0),
	ProviderID INT NULL,
	StartDate DATETIME NOT NULL,
	StopDate DATETIME NOT NULL,
	Evening BIT NOT NULL DEFAULT (0),
	Weekend BIT NOT NULL DEFAULT (0),
	PaymentTypeID TINYINT NOT NULL,
	RateTypeID TINYINT NOT NULL,
	CareTimeID TINYINT NOT NULL,
	Rate SMALLMONEY NOT NULL,
	Units NUMERIC (5, 2) NOT NULL,
	Total MONEY NOT NULL,
	MonthlyTotal MONEY NULL,
	RMREffectiveDate DATETIME NULL,
	RMRMultiplierEffectiveDate DATETIME NULL,
	RMRDescriptionID INT NULL,
	RMRMultiplier NUMERIC (4, 3) NOT NULL DEFAULT (1),
	RMRRate MONEY NOT NULL DEFAULT (0),
	InExcessOfMonthlyRMR BIT NOT NULL DEFAULT (0),
	Breakfast BIT NOT NULL DEFAULT (0),
	Lunch BIT NOT NULL DEFAULT (0),
	Snack BIT NOT NULL DEFAULT (0),
	Dinner BIT NOT NULL DEFAULT (0))
	
CREATE TABLE #tmpChildSchool
	(ChildID INT NOT NULL,
	SchoolID INT NOT NULL,
	SchoolTrackID INT NULL,
	CalendarDate DATETIME NOT NULL)

CREATE TABLE #tmpDaysPerMonth
	(ScheduleID INT NOT NULL,
	AttendanceRateTypeID INT NULL,
	ProgramID INT NOT NULL,
	MonthStart DATETIME NOT NULL,
	MonthStop DATETIME NOT NULL,
	DaysPerMonth INT NOT NULL)

IF @criDebug = 1
	BEGIN
		PRINT	'Calculation begun at ' + CONVERT(VARCHAR, GETDATE(), 8)
		PRINT	''
	END

/* If calculating for CARE application, don't return row counts */
IF @criDebug = 0
	SET NOCOUNT ON

/* If schedule, child, or family ID is passed as criterion,
we can set other criteria variables */
IF @criScheduleID > 0
	SELECT	@criChildID = ChildID,
			@criProviderID = ProviderID
	FROM	tblSchedule (NOLOCK)
	WHERE	ScheduleID = @criScheduleID

IF @criChildID > 0
	SELECT	@criFamilyID = FamilyID
	FROM	tblChild (NOLOCK)
	WHERE	ChildID = @criChildID

--IF @criFamilyID > 0
--	SELECT	@criDivisionID = DivisionID
--	FROM	tblFamily (NOLOCK)
--	WHERE	FamilyID = @criFamilyID

/* Verify criteria */
IF @criDebug = 1
	SELECT	@criStartDate AS StartDate,
			@criStopDate AS StopDate,
			@criOption AS CalcOption,
			@criFamilyID AS FamilyID,
			@criChildID AS ChildID,
			@criProgramID AS ProgramID,
			@criScheduleID AS ScheduleID,
			@criProviderID AS ProviderID,
			@criSpecialistID AS SpecialistID

/* Declare constants */
DECLARE	@constRateTypeCode_Hourly CHAR (2),
		@constRateTypeCode_Daily CHAR (2),
		@constRateTypeCode_Weekly CHAR (2),
		@constRateTypeCode_Monthly CHAR (2),
		@constRateTypeID_Hourly TINYINT,
		@constRateTypeID_Daily TINYINT,
		@constRateTypeID_Weekly TINYINT,
		@constRateTypeID_Monthly TINYINT,
		@constPaymentTypeCode_Regular CHAR (2),
		@constPaymentTypeCode_Vacation CHAR (2),
		@constPaymentTypeCode_FixedFee CHAR (2),
		@constPaymentTypeCode_FamilyFee CHAR (2),
		@constPaymentTypeID_Regular TINYINT,
		@constPaymentTypeID_Vacation TINYINT,
		@constPaymentTypeID_FixedFee TINYINT,
		@constPaymentTypeID_FamilyFee TINYINT,
		@constCareTimeCode_FullTime CHAR (2),
		@constCareTimeCode_PartTime CHAR (2),
		@constCareTimeID_FullTime TINYINT,
		@constCareTimeID_PartTime TINYINT,
		@constFTCutoff_Hourly NUMERIC (5, 2),
		@constFTCutoff_Daily NUMERIC (5, 2),
		@constFTCutoff_Weekly NUMERIC (5, 2),
		@constFTCutoff_Monthly NUMERIC (5, 2)

/* Declare option variables */
DECLARE	@optFamilyFirstServedDate BIT,
		@optFamilyCertStartDate BIT,
		@optFamilyCertStopDate BIT,
		@optFamilyTermDate BIT,
		@optFamilyCalWorksCashAidTermDate BIT,
		@optFamilyCalWorksIneligibilityDate BIT,
		@optFamilyCalWorksStopDate BIT,
		@optChildFirstEnrolledDate BIT,
		@optChildTermDate BIT,
		@optChildLOADate BIT,
		@optProviderServiceStartDate BIT,
		@optProviderServiceStopDate BIT,
		@optProviderDenialDate BIT,
		@optProviderOnHold BIT,
		@optScheduleStartDate BIT,
		@optScheduleStopDate BIT,
		@optIncludeFamilyFees BIT,
		@optDeductFamilyFees BIT,
		@optEnableProviderRateBook BIT,
		@optPaymentDetailSummary TINYINT,
		@optFeeDetail BIT,
		@optHoliday BIT,
		@optPayExcusedAbsences BIT,
		@optPayUnexcusedAbsences BIT,
		@optRemoveZeroValue BIT,
		@optTrackPriority BIT,
		@optPreventPaymentsInExcessOfMonthlyRMR TINYINT,
		@optProgramSource TINYINT,
		@optSiblingDiscountPercentage NUMERIC (5, 2),
		@optRMROverride TINYINT,
		@optFullFeeChargeHolidayAbsenceNonOperation BIT,
		@optProrationMethod TINYINT,
		@optPerformRMRValidation BIT,
		@optAutoSetRateType BIT

/* Declare procedure variables */
DECLARE	--If calculating for a single family, are there fees?
		@procFeeExists BIT,
		--Start date for the current month's calculation
		@procStartDate DATETIME,
		--Stop date for the current month's calculation
		@procStopDate DATETIME,
		--Current month number being processed; used for projection status
		@procCounter TINYINT,
		--Total number of months being processed; used for projection status
		@procMaxCounter TINYINT,
		--Flag for whether projections have been cancelled
		@procCancelled BIT,
		--Message for display when debugging
		@procDebugMessage VARCHAR (100),
		@procDebugStartTime DATETIME,
		@procCalculationID INT,
		--RMR validation variables
		@procRMREffectiveDate DATETIME,
		--Counters for current/max number of weeks
		@procCurrentWeek TINYINT,
		@procMaxWeek TINYINT

/* Declare variables for running SQL strings */
DECLARE	@strInsert NVARCHAR (4000),
		--Specialized variable used for generating family list for family fees
		@strFamilyInsert NVARCHAR (4000),
		@strUpdate NVARCHAR (4000),
		@strDelete NVARCHAR (4000),
		@strSelect NVARCHAR (4000),
		--Specialized variable used for generating family list for family fees
		@strFamilySelect NVARCHAR (4000),
		@strSet NVARCHAR (4000),
		@strFrom NVARCHAR (4000),
		--Specialized variable used for projection deletion
		@strProjectionFrom NVARCHAR (4000),
		@strWhere NVARCHAR (4000),
		--Specialized variable used for family fee to store child-specific criteria
		@strWhereChild NVARCHAR (4000),
		--Specialized variable used for projection deletion
		@strProjectionWhere NVARCHAR (4000),
		@strGroupBy NVARCHAR (4000),
		@strOrderBy NVARCHAR (4000),
		@strHaving NVARCHAR (4000),
		@strOption NVARCHAR (4000),
		@strSQL NVARCHAR (4000)

DECLARE @procRMRCapped BIT

SELECT @procRMRCapped = 0		

/* Set constants */
--Set rate type codes for all rate types
SELECT	@constRateTypeCode_Hourly = '01',
		@constRateTypeCode_Daily = '02',
		@constRateTypeCode_Weekly = '03',
		@constRateTypeCode_Monthly = '04'

--Set rate type ID for hourly rate type
SELECT	@constRateTypeID_Hourly = RateTypeID
FROM	tlkpRateType (NOLOCK)
WHERE	RateTypeCode = @constRateTypeCode_Hourly

--Set rate type ID for daily rate type.  Used
--as a constant for family fee inserts
SELECT	@constRateTypeID_Daily = RateTypeID
FROM	tlkpRateType (NOLOCK)
WHERE	RateTypeCode = @constRateTypeCode_Daily

--Set rate type ID for weekly rate type
SELECT	@constRateTypeID_Weekly = RateTypeID
FROM	tlkpRateType (NOLOCK)
WHERE	RateTypeCode = @constRateTypeCode_Weekly

--Set rate type ID for monthly rate type.  Used
--as a constant for fixed fee inserts
SELECT	@constRateTypeID_Monthly = RateTypeID
FROM	tlkpRateType (NOLOCK)
WHERE	RateTypeCode = @constRateTypeCode_Monthly

--Set payment type codes for each payment type
SELECT	@constPaymentTypeCode_Regular = '01',
		@constPaymentTypeCode_Vacation = '02',
		@constPaymentTypeCode_FixedFee = '04',
		@constPaymentTypeCode_FamilyFee = '05'

--Set payment type IDs for each payment type
SELECT	@constPaymentTypeID_Regular = PaymentTypeID
FROM	tlkpPaymentType (NOLOCK)
WHERE	PaymentTypeCode = @constPaymentTypeCode_Regular

SELECT	@constPaymentTypeID_Vacation = PaymentTypeID
FROM	tlkpPaymentType (NOLOCK)
WHERE	PaymentTypeCode = @constPaymentTypeCode_Vacation

SELECT	@constPaymentTypeID_FixedFee = PaymentTypeID
FROM	tlkpPaymentType (NOLOCK)
WHERE	PaymentTypeCode = @constPaymentTypeCode_FixedFee

SELECT	@constPaymentTypeID_FamilyFee = PaymentTypeID
FROM	tlkpPaymentType (NOLOCK)
WHERE	PaymentTypeCode = @constPaymentTypeCode_FamilyFee

--Set care time codes for each care time
SELECT	@constCareTimeCode_FullTime = '01',
		@constCareTimeCode_PartTime = '02'

--Set care time IDs for each care time
SELECT	@constCareTimeID_FullTime = CareTimeID
FROM	tlkpCareTime (NOLOCK)
WHERE	CareTimeCode = @constCareTimeCode_FullTime

SELECT	@constCareTimeID_PartTime = CareTimeID
FROM	tlkpCareTime (NOLOCK)
WHERE	CareTimeCode = @constCareTimeCode_PartTime

/* Set option variables */
--Program source (child/schedule detail)
EXEC spGetSetupOption 'ProgramSource', @optProgramSource OUTPUT

--Sibling discount percentage
EXEC spGetSetupOption 'SiblingDiscountPercentage', @optSiblingDiscountPercentage OUTPUT

--RMR override (prevent, warn, calculate co-payment - for purposes of this calculation prevent and calculate co-pay are the same)
EXEC spGetSetupOption 'RMROverride', @optRMROverride OUTPUT

--For full-fee/private families, charge holidays, absences, and provider days of non-operation regardless of calc settings?
EXEC spGetSetupOption 'FullFeeChargeHolidayAbsenceNonOperation', @optFullFeeChargeHolidayAbsenceNonOperation OUTPUT

--Time sheet/provider payment
IF @criOption = 1
	BEGIN
		EXEC spGetSetupOption 'TimeSheetFirstServedStart', @optFamilyFirstServedDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetCertStart', @optFamilyCertStartDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetCertStop', @optFamilyCertStopDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetFamilyTermStop', @optFamilyTermDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetCashAidTermStop', @optFamilyCalWorksCashAidTermDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetIneligibilityStop', @optFamilyCalWorksIneligibilityDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetCalWorksStop', @optFamilyCalWorksStopDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetFirstEnrolledStart', @optChildFirstEnrolledDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetChildTermStop', @optChildTermDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetLOAStop', @optChildLOADate OUTPUT
		EXEC spGetSetupOption 'TimeSheetProviderServiceStart', @optProviderServiceStartDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetProviderServiceStop', @optProviderServiceStopDate OUTPUT
		EXEC spGetSetupOption 'TimeSheetProviderDenialStop', @optProviderDenialDate OUTPUT

		--On hold status is handled via group-level security rather than a setup option.
		--On the single-entry Time Sheet Entry form user will be prevented from calculating if the provider is on hold and the user does not
		--have appropriate rights.
		--For multiple-entry TSE a check has to be added to the calculation to exclude providers on hold if the user does not have rights.
		SELECT	@optProviderOnHold =	CASE s.CanEdit
											WHEN 1
												THEN 0
											WHEN 0
												THEN 1
										END
		FROM	tlnkSecurity s (NOLOCK)
				JOIN tlkpUser u (NOLOCK)
					ON s.GroupID = u.GroupID
				JOIN tlkpObject o (NOLOCK)
					ON s.ObjectID = o.ObjectID
		WHERE	o.ObjectName = 'frmTimeSheetEntry_OnHoldProviderPayment'
				AND u.UserID = @criUserID

		SELECT	@optScheduleStartDate = 1
		SELECT	@optScheduleStopDate = 1
		EXEC spGetSetupOption 'TimeSheetFamilyFee', @optIncludeFamilyFees OUTPUT
		EXEC spGetSetupOption 'TimeSheetFamilyFee', @optDeductFamilyFees OUTPUT
		EXEC spGetSetupOption 'EnableProviderRateBook', @optEnableProviderRateBook OUTPUT
		EXEC spGetSetupOption 'PaymentDetailSummary', @optPaymentDetailSummary OUTPUT
		SELECT	@optFeeDetail = 0
		EXEC spGetSetupOption 'TimeSheetHoliday', @optHoliday OUTPUT
		EXEC spGetSetupOption 'TimeSheetPayExcusedAbsences', @optPayExcusedAbsences OUTPUT
		EXEC spGetSetupOption 'TimeSheetPayUnexcusedAbsences', @optPayUnexcusedAbsences OUTPUT
		EXEC spGetSetupOption 'SchoolTrackVacation', @optTrackPriority OUTPUT
		EXEC spGetSetupOption 'TimeSheetRemoveZeroValue', @optRemoveZeroValue OUTPUT
		EXEC spGetSetupOption 'TimeSheetPreventExcessOfMonthlyRMR', @optPreventPaymentsInExcessOfMonthlyRMR OUTPUT
		SELECT	@optPreventPaymentsInExcessOfMonthlyRMR =	CASE @optPreventPaymentsInExcessOfMonthlyRMR
																--Don't prevent payments
																WHEN 1
																	THEN 0
																--Prevent payments
																WHEN 2
																	THEN 1
																--Notify user (handled in time sheet entry)
																WHEN 3
																	THEN 0
																ELSE 0
															END
		EXEC spGetSetupOption 'TimeSheetRMRValidation', @optPerformRMRValidation OUTPUT
				
		IF @criUseAttendance = 0
			EXEC spGetSetupOption 'TimeSheetScheduleProrationMethod', @optProrationMethod OUTPUT
		ELSE
			EXEC spGetSetupOption 'TimeSheetAttendanceProrationMethod', @optProrationMethod OUTPUT

		EXEC spGetSetupOption 'TimeSheetAutoSetRateType', @optAutoSetRateType OUTPUT
	END

--Projection
IF @criOption = 2
	BEGIN
		EXEC spGetSetupOption 'ProjectFirstServedStart', @optFamilyFirstServedDate OUTPUT
		EXEC spGetSetupOption 'ProjectCertStart', @optFamilyCertStartDate OUTPUT
		EXEC spGetSetupOption 'ProjectCertStop', @optFamilyCertStopDate OUTPUT
		EXEC spGetSetupOption 'ProjectFamilyTermStop', @optFamilyTermDate OUTPUT
		EXEC spGetSetupOption 'ProjectCashAidTermStop', @optFamilyCalWorksCashAidTermDate OUTPUT
		EXEC spGetSetupOption 'ProjectIneligibilityStop', @optFamilyCalWorksIneligibilityDate OUTPUT
		EXEC spGetSetupOption 'ProjectCalWorksStop', @optFamilyCalWorksStopDate OUTPUT
		EXEC spGetSetupOption 'ProjectFirstEnrolledStart', @optChildFirstEnrolledDate OUTPUT
		EXEC spGetSetupOption 'ProjectChildTermStop', @optChildTermDate OUTPUT
		EXEC spGetSetupOption 'ProjectLOAStop', @optChildLOADate OUTPUT
		EXEC spGetSetupOption 'ProjectProviderServiceStart', @optProviderServiceStartDate OUTPUT
		EXEC spGetSetupOption 'ProjectProviderServiceStop', @optProviderServiceStopDate OUTPUT
		EXEC spGetSetupOption 'ProjectProviderDenialStop', @optProviderDenialDate OUTPUT
		EXEC spGetSetupOption 'ProjectProviderOnHold', @optProviderOnHold OUTPUT
		SELECT	@optScheduleStartDate = 1
		EXEC spGetSetupOption 'ProjectScheduleStop', @optScheduleStopDate OUTPUT
		EXEC spGetSetupOption 'ProjectFamilyFee', @optIncludeFamilyFees OUTPUT
		EXEC spGetSetupOption 'ProjectFamilyFee', @optDeductFamilyFees OUTPUT
		EXEC spGetSetupOption 'EnableProviderRateBook', @optEnableProviderRateBook OUTPUT
		SELECT	@optPaymentDetailSummary = 4
		SELECT	@optFeeDetail = 0
		EXEC spGetSetupOption 'ProjectHoliday', @optHoliday OUTPUT
		EXEC spGetSetupOption 'ProjectPayExcusedAbsences', @optPayExcusedAbsences OUTPUT
		EXEC spGetSetupOption 'ProjectPayUnexcusedAbsences', @optPayUnexcusedAbsences OUTPUT
		SELECT	@optRemoveZeroValue = 0
		EXEC spGetSetupOption 'SchoolTrackVacation', @optTrackPriority OUTPUT
		EXEC spGetSetupOption 'ProjectPreventExcessOfMonthlyRMR', @optPreventPaymentsInExcessOfMonthlyRMR OUTPUT
		SELECT	@optPreventPaymentsInExcessOfMonthlyRMR =	CASE @optPreventPaymentsInExcessOfMonthlyRMR
																--Don't prevent payments
																WHEN 1
																	THEN 0
																--Prevent payments
																WHEN 2
																	THEN 1
																--Notify user (not applicable for projections)
																WHEN 3
																	THEN 1
																ELSE 0
															END
		EXEC spGetSetupOption 'ProjectProrationMethod', @optProrationMethod OUTPUT
		EXEC spGetSetupOption 'ProjectRMRValidation', @optPerformRMRValidation OUTPUT
		SELECT	@optAutoSetRateType = 0
	END

--Family fee and family fee adjustments
IF @criOption = 3 OR @criOption = 4
	BEGIN
		EXEC spGetSetupOption 'FamilyFeeFirstServedStart', @optFamilyFirstServedDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeCertStart', @optFamilyCertStartDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeCertStop', @optFamilyCertStopDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeFamilyTermStop', @optFamilyTermDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeCashAidTermStop', @optFamilyCalWorksCashAidTermDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeIneligibilityStop', @optFamilyCalWorksIneligibilityDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeCalWorksStop', @optFamilyCalWorksStopDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeFirstEnrolledStart', @optChildFirstEnrolledDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeChildTermStop', @optChildTermDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeLOAStop', @optChildLOADate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeProviderServiceStart', @optProviderServiceStartDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeProviderServiceStop', @optProviderServiceStopDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeProviderDenialStop', @optProviderDenialDate OUTPUT
		EXEC spGetSetupOption 'FamilyFeeProviderOnHold', @optProviderOnHold OUTPUT
		SELECT	@optScheduleStartDate = 1
		SELECT	@optScheduleStopDate = 1
		SELECT	@optIncludeFamilyFees = 1
		SELECT	@optDeductFamilyFees = 0
		EXEC spGetSetupOption 'EnableProviderRateBook', @optEnableProviderRateBook OUTPUT
		SELECT	@optPaymentDetailSummary = 2
		EXEC spGetSetupOption 'FeeDetail', @optFeeDetail OUTPUT
		EXEC spGetSetupOption 'FamilyFeeHoliday', @optHoliday OUTPUT
		EXEC spGetSetupOption 'FamilyFeePayExcusedAbsences', @optPayExcusedAbsences OUTPUT
		EXEC spGetSetupOption 'FamilyFeePayUnexcusedAbsences', @optPayUnexcusedAbsences OUTPUT
		EXEC spGetSetupOption 'FamilyFeeRemoveZeroValue', @optRemoveZeroValue OUTPUT
		EXEC spGetSetupOption 'SchoolTrackVacation', @optTrackPriority OUTPUT
		SELECT	@optPreventPaymentsInExcessOfMonthlyRMR = 0
		EXEC spGetSetupOption 'FamilyFeeProrationMethod', @optProrationMethod OUTPUT
		SELECT	@optAutoSetRateType = 0
	END

/* Set procedure variables */
SELECT	@procStartDate = @criStartDate,
		@procStopDate =	CASE
							--Start date and stop date fall in different months or years; use last day of first month
							WHEN DATEPART(MONTH, @criStopDate) <> DATEPART(MONTH, @criStartDate) OR DATEPART(YEAR, @criStopDate) <> DATEPART(YEAR, @criStartDate)
								THEN DATEADD(DAY, -1, DATEADD(MONTH, 1, DATEADD(DAY, - DATEPART(DAY, @criStartDate) + 1, @criStartDate)))
							--Start date and stop date fall in the same month and year; use criteria stop date
							ELSE @criStopDate
						END

SELECT	@procCounter = 0,
		@procMaxCounter = DATEDIFF(MONTH, @criStartDate, @criStopDate) + 1,
		@procCancelled = 0

IF @criDebug = 1
	SELECT	@procCalculationID = ISNULL(MAX(CalculationID), 0) + 1
	FROM	tblCalculationDebug (NOLOCK)

/* Set variables for running SQL strings */
--OPTION clause
--This clause will be the same every time and is always the last part of the statement
--Prior to Plan Guides, but after plans became re-entrant (SQL Server 7.0?), you had to determine when a plan was working
--and then hope the option (keep plan) would "keep" and not recompile.
--OPTION(KEEP PLAN) was not-documented at the time and could be droped or changed
--w/o violating the EULA

SELECT	@strOption = 'OPTION (KEEP PLAN)'

/* Set FT cutoffs for each program */
--Insert default FT cutoff for each rate type
INSERT	#tmpFTCutoff
	(ProgramID,
	RateTypeCode,
	EffectiveDate,
	FTCutoffTypeProviderPayment,
	PTCutoffProviderPayment,
	FTCutoffProviderPayment,
	FTCutoffTypeFamilyFee,
	PTCutoffFamilyFee,
	FTCutoffFamilyFee)
SELECT	p.ProgramID,
		ft.RateTypeCode,
		ft.EffectiveDate,
		0,
		0,
		ft.FTCutoffProviderPayment,
		0,
		0,
		ft.FTCutoffFamilyFee
FROM	tblProgram p (NOLOCK),
		tlkpFTCutoff ft (NOLOCK)

--Enter FT cutoffs by program
--Hourly/daily
UPDATE	ft
SET		FTCutoffTypeProviderPayment = p.FTCutoffTypeProviderPayment,
		PTCutoffProviderPayment =	CASE
										WHEN p.FTCutoffTypeProviderPayment IN (0, 1)
											THEN p.HourlyDailyPTCutoffProviderPayment
										WHEN p.FTCutoffTypeProviderPayment = 2
											THEN p.WeeklyMonthlyPTCutoffProviderPayment
										ELSE 0
									END,
		FTCutoffProviderPayment =	CASE
										WHEN p.FTCutoffTypeProviderPayment IN (0, 1)
											THEN p.HourlyDailyFTCutoffProviderPayment
										WHEN p.FTCutoffTypeProviderPayment = 2
											THEN p.WeeklyMonthlyFTCutoffProviderPayment
										ELSE ft.FTCutoffProviderPayment
									END,
		FTCutoffTypeFamilyFee = p.FTCutoffTypeFamilyFee,
		PTCutoffFamilyFee =	CASE
								WHEN p.FTCutoffTypeFamilyFee IN (0, 1)
									THEN p.HourlyDailyPTCutoffFamilyFee
								WHEN p.FTCutoffTypeFamilyFee = 2
									THEN p.WeeklyMonthlyPTCutoffFamilyFee
								ELSE 0
							END,
		FTCutoffFamilyFee =	CASE
								WHEN p.FTCutoffTypeFamilyFee IN (0, 1)
									THEN p.HourlyDailyFTCutoffFamilyFee
								WHEN p.FTCutoffTypeFamilyFee = 2
									THEN p.WeeklyMonthlyFTCutoffFamilyFee
								ELSE ft.FTCutoffFamilyFee
							END
FROM	#tmpFTCutoff ft
		JOIN tlkpFTCutoffProgram p (NOLOCK)
			ON ft.ProgramID = p.ProgramID
				AND ft.EffectiveDate = p.EffectiveDate
WHERE	ft.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)

--Weekly/monthly
UPDATE	ft
SET		FTCutoffTypeProviderPayment = p.FTCutoffTypeProviderPayment,
		PTCutoffProviderPayment =	CASE
										WHEN p.FTCutoffTypeProviderPayment = 1
											THEN p.HourlyDailyPTCutoffProviderPayment
										WHEN p.FTCutoffTypeProviderPayment IN (0, 2)
											THEN p.WeeklyMonthlyPTCutoffProviderPayment
										ELSE 0
									END,
		FTCutoffProviderPayment =	CASE
										WHEN p.FTCutoffTypeProviderPayment = 1
											THEN p.HourlyDailyFTCutoffProviderPayment
										WHEN p.FTCutoffTypeProviderPayment IN (0, 2)
											THEN p.WeeklyMonthlyFTCutoffProviderPayment
										ELSE ft.FTCutoffProviderPayment
									END,
		FTCutoffTypeFamilyFee = p.FTCutoffTypeFamilyFee,
		PTCutoffFamilyFee =	CASE
								WHEN p.FTCutoffTypeFamilyFee = 1
									THEN p.HourlyDailyPTCutoffFamilyFee
								WHEN p.FTCutoffTypeFamilyFee IN (0, 2)
									THEN p.WeeklyMonthlyPTCutoffFamilyFee
								ELSE 0
							END,
		FTCutoffFamilyFee =	CASE
								WHEN p.FTCutoffTypeFamilyFee = 1
									THEN p.HourlyDailyFTCutoffFamilyFee
								WHEN p.FTCutoffTypeFamilyFee IN (0, 2)
									THEN p.WeeklyMonthlyFTCutoffFamilyFee
								ELSE ft.FTCutoffFamilyFee
							END
FROM	#tmpFTCutoff ft
		JOIN tlkpFTCutoffProgram p (NOLOCK)
			ON ft.ProgramID = p.ProgramID
				AND ft.EffectiveDate = p.EffectiveDate
WHERE	ft.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)

/* Initialize cancellation and status table */
--Projection only
IF @criOption = 2
	BEGIN
		DELETE	tblProjectionCancel

		DELETE	tblProjectionStatus

		INSERT	tblProjectionStatus
			(TotalRecordCount,
			CurrentRecord,
			StartDate,
			StopDate,
			CurrentDate)
		VALUES
			(@procMaxCounter,
			@procCounter,
			@criStartDate,
			@criStopDate,
			@procStartDate)
	END

/* If including family fees and calculating for a single family, 
check to see if any fees exist for the family */
IF @criFamilyID > 0 AND @optIncludeFamilyFees = 1
	BEGIN
		SELECT	@procFeeExists =	--CASE
									--	WHEN EXISTS	(SELECT	*
									--				FROM	tblFamilyIncomeFeeHistory
									--				WHERE	FamilyID = @criFamilyID
									--						AND FullTimeFee > 0
									--						AND PartTimeFee > 0)
									--			AND WaiveFee = 0
									/*		THEN */1
									--	ELSE 0
									--END
		FROM	tblFamily (NOLOCK)
		WHERE	FamilyID = @criFamilyID

		IF @procFeeExists = 0
			SELECT	@optIncludeFamilyFees = 0,
					@optDeductFamilyFees = 0
	END

/* Delete old data */
SELECT	@procDebugMessage = 'Old data deletion'

IF @criDebug = 1
	EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

--Build standard SQL string for deletion from result tables
--DELETE clause
SELECT	@strDelete = 'DELETE res '

--FROM clause
--We will add the first table on later; for now, list the joined tables
SELECT	@strFrom = ''

--Family
IF @criDivisionID <> 0
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tblFamily fam (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON res.FamilyID = fam.FamilyID '
	END

--Specialist
IF @criSpecialistID <> 0
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tlnkFamilySpecialist fs (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON res.FamilyID = fs.FamilyID '
	END

--WHERE clause
SELECT	@strWhere = ''

--Family ID
IF @criFamilyID <> 0
	SELECT	@strWhere = @strWhere + 'AND res.FamilyID = @criFamilyID '

--Child ID
IF @criChildID <> 0
	SELECT	@strWhere = @strWhere + 'AND res.ChildID = @criChildID '

--ScheduleID
IF @criScheduleID <> 0
	SELECT	@strWhere = @strWhere + 'AND res.ScheduleID = @criScheduleID '

--ProviderID
IF @criProviderID <> 0
	SELECT	@strWhere = @strWhere + 'AND res.ProviderID = @criProviderID '

--Program ID
IF @criProgramID <> 0
	SELECT	@strWhere = @strWhere + 'AND res.ProgramID = @criProgramID '

--Specialist ID
IF @criSpecialistID <> 0
	SELECT	@strWhere = @strWhere + 'AND fs.SpecialistID = @criSpecialistID '

--Division ID
IF @criDivisionID <> 0
	SELECT	@strWhere = @strWhere + 'AND fam.DivisionID = @criDivisionID '

--Time sheet/provider payment
IF @criOption = 1
	BEGIN
		--DELETE clause
		--Use standard clause

		--FROM clause
		--Time sheet
		--Add to the beginning of the clause
		SELECT	@strFrom = 'FROM tblTimeSheetResult res ' + @strFrom

		--WHERE clause
		--Service dates
		--Add to the beginning of the clause
		SELECT	@strWhere = 'WHERE res.StartDate BETWEEN @criStartDate AND @criStopDate ' + @strWhere

		SELECT	@strSQL = @strDelete + @strFrom + @strWhere + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME,
									@criFamilyID INT,
									@criChildID INT,
									@criScheduleID INT,
									@criProviderID INT,
									@criProgramID INT,
									@criSpecialistID INT,
									@criDivisionID INT',
									@criStartDate,
									@criStopDate,
									@criFamilyID,
									@criChildID,
									@criScheduleID,
									@criProviderID,
									@criProgramID,
									@criSpecialistID,
									@criDivisionID
	END

--Projection
IF @criOption = 2
	BEGIN
		--Delete projection results
		--DELETE clause
		--Use standard clause

		--FROM clause
		--Projection result
		--Need a separate variable here because we need to repeat for projection error
		--Add to the beginning of the clause
		SELECT	@strProjectionFrom = 'FROM tblProjectionResult res ' + @strFrom

		--WHERE clause
		--Service dates
		--Need a separate variable here because we need to repeat for projection error
		--Add to the beginning of the clause
		SELECT	@strProjectionWhere = 'WHERE res.PeriodStart BETWEEN @criStartDate AND @criStopDate ' + @strWhere

		SELECT	@strSQL = @strDelete + @strProjectionFrom + @strProjectionWhere + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME,
									@criFamilyID INT,
									@criChildID INT,
									@criScheduleID INT,
									@criProviderID INT,
									@criProgramID INT,
									@criSpecialistID INT,
									@criDivisionID INT',
									@criStartDate,
									@criStopDate,
									@criFamilyID,
									@criChildID,
									@criScheduleID,
									@criProviderID,
									@criProgramID,
									@criSpecialistID,
									@criDivisionID

		--Delete projection errors
		--DELETE clause
		--Use standard clause

		--FROM clause
		--Projection error
		--Add to the beginning of the clause
		SELECT	@strProjectionFrom = 'FROM tblProjectionError res ' + @strFrom

		--WHERE clause
		--Service dates
		--Add to the beginning of the clause
		SELECT	@strProjectionWhere = 'WHERE res.ErrorDate BETWEEN @criStartDate AND @criStopDate ' + @strWhere

		SELECT	@strSQL = @strDelete + @strProjectionFrom + @strProjectionWhere + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME,
									@criFamilyID INT,
									@criChildID INT,
									@criScheduleID INT,
									@criProviderID INT,
									@criProgramID INT,
									@criSpecialistID INT,
									@criDivisionID INT',
									@criStartDate,
									@criStopDate,
									@criFamilyID,
									@criChildID,
									@criScheduleID,
									@criProviderID,
									@criProgramID,
									@criSpecialistID,
									@criDivisionID
	END

--Family fee and Family Fee Adjusments
IF @criOption = 3 OR @criOption = 4
	BEGIN
		--DELETE clause
		--Use standard clause

		--FROM clause
		--Family fee
		--Add to the beginning of the clause
		IF @criOption = 3
			SELECT	@strFrom = 'FROM tblFamilyFeeResult res ' + @strFrom
		ELSE
			SELECT	@strFrom = 'FROM tblFamilyFeeAdjustmentResult res ' + @strFrom


		--WHERE clause
		--Service dates
		--Add to the beginning of the clause
		SELECT	@strWhere = 'WHERE res.StartDate BETWEEN @criStartDate AND @criStopDate ' + @strWhere

		SELECT	@strSQL = @strDelete + @strFrom + @strWhere + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME,
									@criFamilyID INT,
									@criChildID INT,
									@criScheduleID INT,
									@criProviderID INT,
									@criProgramID INT,
									@criSpecialistID INT,
									@criDivisionID INT',
									@criStartDate,
									@criStopDate,
									@criFamilyID,
									@criChildID,
									@criScheduleID,
									@criProviderID,
									@criProgramID,
									@criSpecialistID,
									@criDivisionID
	END

IF @criDebug = 1
	EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

/* Insert calendar information */
SELECT	@procDebugMessage = 'Calendar data insertion to temp table'

IF @criDebug = 1
	EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

INSERT	#tmpCalendar
	(CalendarDate,
	DayOfWeek,
	WeekStart,
	WeekStop,
	MonthStart,
	MonthStop)
SELECT	DISTINCT
		cal.CalendarDate,
		cal.DayOfWeek,
		cal.WeekStart,
		cal.WeekStop,
		cal.MonthStart,
		cal.MonthStop
FROM	tblCalendar cal (NOLOCK)
WHERE	--Include previous month to properly determine true week start and week stop
		cal.CalendarDate BETWEEN DATEADD(MONTH, -1, @criStartDate) AND DATEADD(MONTH, 1, @criStopDate)
		--Holidays were previously excluded here but since this table will be used for other things they need to be excluded later
OPTION	(KEEP PLAN)

IF @criDebug = 1
	EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

/* Generate initial list of families/schedules for entire calculation period */
SELECT	@procDebugMessage = 'Schedule insertion into temp table'

IF @criDebug = 1
	EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

--Generate components of the SQL string that will be the same whether or not fees
--are included
--INSERT clause (for schedules)
SELECT	@strInsert = 'INSERT #tmpScheduleCopyInitial '
SELECT	@strInsert = @strInsert + '(ScheduleID, '
SELECT	@strInsert = @strInsert + 'ChildID, '
SELECT	@strInsert = @strInsert + 'ProviderID, '
SELECT	@strInsert = @strInsert + 'ClassroomID, '
SELECT	@strInsert = @strInsert + 'FamilyID, '
SELECT	@strInsert = @strInsert + 'ExtendedSchedule, '
SELECT	@strInsert = @strInsert + 'StartDate, '
SELECT	@strInsert = @strInsert + 'StopDate, '
SELECT	@strInsert = @strInsert + 'SiblingDiscount, '
SELECT	@strInsert = @strInsert + 'WeeklyHoursRegular, '
SELECT	@strInsert = @strInsert + 'WeeklyHoursVacation, '
SELECT	@strInsert = @strInsert + 'PrimaryProvider, '
SELECT	@strInsert = @strInsert + 'PayFamily, '
SELECT	@strInsert = @strInsert + 'SpecialNeedsRMRMultiplier, '
SELECT	@strInsert = @strInsert + 'FamilyFirstServedDate, '
SELECT	@strInsert = @strInsert + 'FamilyCertStartDate, '
SELECT	@strInsert = @strInsert + 'FamilyCertStopDate, '
SELECT	@strInsert = @strInsert + 'FamilyTermDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksCashAidTermDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksIneligibilityDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage1StartDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage1StopDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage2StartDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage2StopDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage3StartDate, '
SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage3StopDate, '
SELECT	@strInsert = @strInsert + 'ChildFirstEnrolled, '
SELECT	@strInsert = @strInsert + 'ChildTermDate, '
SELECT	@strInsert = @strInsert + 'ProviderServiceStartDate, '
SELECT	@strInsert = @strInsert + 'ProviderServiceStopDate, '
SELECT	@strInsert = @strInsert + 'ProviderDenied, '
SELECT	@strInsert = @strInsert + 'ProviderDenialDate) '

--SELECT clause
SELECT	@strSelect = 'SELECT DISTINCT '
SELECT	@strSelect = @strSelect + 'sched.ScheduleID, '
SELECT	@strSelect = @strSelect + 'sched.ChildID, '
SELECT	@strSelect = @strSelect + 'sched.ProviderID, '
SELECT	@strSelect = @strSelect + 'sched.ClassroomID, '
SELECT	@strSelect = @strSelect + 'chi.FamilyID, '
SELECT	@strSelect = @strSelect + '0, '
SELECT	@strSelect = @strSelect + 'sched.StartDate, '
SELECT	@strSelect = @strSelect + 'sched.StopDate, '
SELECT	@strSelect = @strSelect + 'sched.SiblingDiscount, '
SELECT	@strSelect = @strSelect + 'sched.WeeklyHoursRegular, '
SELECT	@strSelect = @strSelect + 'sched.WeeklyHoursVacation, '
SELECT	@strSelect = @strSelect + 'sched.PrimaryProvider, '
SELECT	@strSelect = @strSelect + 'sched.PayFamily, '
SELECT	@strSelect = @strSelect + 'sched.SpecialNeedsRMRMultiplier, '

IF @optFamilyFirstServedDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.FirstServedDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyCertStartDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.CertStartDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyCertStopDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.CertStopDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyTermDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.TermDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyCalWorksCashAidTermDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.CashAidTermDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyCalWorksIneligibilityDate <> 0
	SELECT	@strSelect = @strSelect + 'fam.IneligibilityDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optFamilyCalWorksStopDate <> 0
	BEGIN
		SELECT	@strSelect = @strSelect + 'fam.Stage1Date, '
		SELECT	@strSelect = @strSelect + 'fam.Stage1Stop, '
		SELECT	@strSelect = @strSelect + 'fam.Stage2Date, '
		SELECT	@strSelect = @strSelect + 'fam.Stage2Stop, '
		SELECT	@strSelect = @strSelect + 'fam.Stage3Date, '
		SELECT	@strSelect = @strSelect + 'fam.Stage3Stop, '
	END
ELSE
	BEGIN
		SELECT	@strSelect = @strSelect + 'NULL, '
		SELECT	@strSelect = @strSelect + 'NULL, '
		SELECT	@strSelect = @strSelect + 'NULL, '
		SELECT	@strSelect = @strSelect + 'NULL, '
		SELECT	@strSelect = @strSelect + 'NULL, '
		SELECT	@strSelect = @strSelect + 'NULL, '
	END

IF @optChildFirstEnrolledDate <> 0
	SELECT	@strSelect = @strSelect + 'chi.FirstEnrolled, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optChildTermDate <> 0
	SELECT	@strSelect = @strSelect + 'chi.TermDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optProviderServiceStartDate <> 0
	SELECT	@strSelect = @strSelect + 'prv.ServiceStartDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optProviderServiceStopDate <> 0
	SELECT	@strSelect = @strSelect + 'prv.ServiceStopDate, '
ELSE
	SELECT	@strSelect = @strSelect + 'NULL, '

IF @optProviderDenialDate <> 0
	BEGIN
		SELECT	@strSelect = @strSelect + 'prv.Denied, '
		SELECT	@strSelect = @strSelect + 'prv.DenialDate '
	END
ELSE
	BEGIN
		SELECT	@strSelect = @strSelect + '0, '
		SELECT	@strSelect = @strSelect + 'NULL '
	END

--FROM clause
--Schedule
SELECT	@strFrom = 'FROM tblSchedule sched (NOLOCK) '

--Child
--Always include child table because we need to link it for family and specialist
SELECT	@strFrom = @strFrom + 'JOIN tblChild chi (NOLOCK) '
SELECT	@strFrom = @strFrom + 'ON sched.ChildID = chi.ChildID '

--Schedule detail/child program
--Allows filtering by program
IF @criProgramID <> 0
	BEGIN
		IF @optProgramSource = 1 --Child level
			BEGIN
				SELECT	@strFrom = @strFrom + 'JOIN tlnkChildProgram cp (NOLOCK) '
				SELECT	@strFrom = @strFrom + 'ON chi.ChildID = cp.ChildID '
			END

		IF @optProgramSource = 2 --Schedule detail level
			BEGIN
				SELECT	@strFrom = @strFrom + 'JOIN tblScheduleDetail det (NOLOCK) '
				SELECT	@strFrom = @strFrom + 'ON sched.ScheduleID = det.ScheduleID '
			END
	END

--Provider
--Allows filtering by:	service dates
--						on hold
--						denial date
IF @optProviderServiceStartDate <> 0
		OR @optProviderServiceStopDate <> 0
		OR @optProviderOnHold <> 0
		OR @optProviderDenialDate <> 0
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tblProvider prv (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON sched.ProviderID = prv.ProviderID '
	END

--Family
--Allows filtering by:	division
--						first served date
--						cert dates
--						term date
--						CalWORKs date
--						cash aid term date
--						ineligibility date
IF @criDivisionID <> 0
		OR @optFamilyFirstServedDate <> 0
		OR @optFamilyCertStartDate <> 0
		OR @optFamilyCertStopDate <> 0
		OR @optFamilyTermDate <> 0
		OR @optFamilyCalWorksStopDate <> 0
		OR @optFamilyCalWorksCashAidTermDate <> 0
		OR @optFamilyCalWorksIneligibilityDate <> 0
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tblFamily fam (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON chi.FamilyID = fam.FamilyID '
	END

--Specialist
--Allows filtering by specialist
IF @criSpecialistID <> 0
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tlnkFamilySpecialist fs (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON chi.FamilyID = fs.FamilyID '
	END

--Attendance
--Allows filtering by whether children have attendance data
IF @criIncludeAttendance = 0
	--Exclude children with attendance data
	BEGIN
		SELECT	@strFrom = @strFrom + 'LEFT JOIN '
		SELECT	@strFrom = @strFrom + '(SELECT DISTINCT ChildID '
		SELECT	@strFrom = @strFrom + 'FROM tblAttendanceHistory (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'WHERE AttendanceDate BETWEEN @criStartDate AND @criStopDate) '
		SELECT	@strFrom = @strFrom + 'att '
		SELECT	@strFrom = @strFrom + 'ON chi.ChildID = att.ChildID '
	END

IF @criIncludeAttendance = 1
	--Include only children with attendance data
	BEGIN
		SELECT	@strFrom = @strFrom + 'JOIN tblAttendanceHistory att (NOLOCK) '
		SELECT	@strFrom = @strFrom + 'ON chi.ChildID = att.ChildID '
	END

--WHERE clause
SELECT	@strWhere = 'WHERE '
SELECT	@strWhereChild = ''

--Service dates
--Always included
SELECT	@strWhere = @strWhere + '(sched.StartDate IS NULL '
SELECT	@strWhere = @strWhere + 'OR sched.StartDate <= @criStopDate) '

SELECT	@strWhere = @strWhere + 'AND (sched.StopDate IS NULL '
SELECT	@strWhere = @strWhere + 'OR sched.StopDate >= @criStartDate) '

--Family ID
IF @criFamilyID <> 0
	SELECT	@strWhere = @strWhere + 'AND chi.FamilyID = @criFamilyID '

--First served date
IF @optFamilyFirstServedDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.FirstServedDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.FirstServedDate <= @criStopDate) '
	END

--Cert dates
IF @optFamilyCertStartDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.CertStartDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.CertStartDate <= @criStopDate) '
	END

IF @optFamilyCertStopDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.CertStopDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.CertStopDate >= @criStartDate) '
	END

--Family term date
IF @optFamilyTermDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.TermDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.TermDate >= @criStartDate) '
	END

--CalWORKs dates
IF @optFamilyCalWorksStopDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.Stage1Stop >= @criStartDate '
		SELECT	@strWhere = @strWhere + 'OR fam.Stage1Stop IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.Stage2Date IS NOT NULL) '

		SELECT	@strWhere = @strWhere + 'AND (fam.Stage2Stop >= @criStartDate '
		SELECT	@strWhere = @strWhere + 'OR fam.Stage2Stop IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.Stage3Date IS NOT NULL) '

		SELECT	@strWhere = @strWhere + 'AND (fam.Stage3Stop >= @criStartDate '
		SELECT	@strWhere = @strWhere + 'OR fam.Stage3Stop IS NULL) '
	END

--Cash aid term date
IF @optFamilyCalWorksCashAidTermDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.CashAidTermDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.CashAidTermDate >= @criStartDate) '
	END

--Ineligibility date
IF @optFamilyCalWorksIneligibilityDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (fam.IneligibilityDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR fam.IneligibilityDate >= @criStartDate) '
	END

--Child ID
--Cannot be included in standard WHERE clause for family insert - put in separate variable
IF @criChildID > 0
	SELECT	@strWhereChild = @strWhereChild + 'AND sched.ChildID = @criChildID '

--First enrolled date
IF @optChildFirstEnrolledDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (chi.FirstEnrolled IS NULL '
		SELECT	@strWhere = @strWhere + 'OR chi.FirstEnrolled <= @criStopDate) '
	END

--Child term date
IF @optChildTermDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (chi.TermDate IS NULL '
		SELECT	@strWhere = @strWhere + 'OR chi.TermDate >= @criStartDate) '
	END

--LOA
--LOA check is removed from initial checking because
--there is now a start and stop date, making the
--check trickier

--Schedule ID
--Cannot be included in standard WHERE clause for family insert - put in separate variable
IF @criScheduleID <> 0
	SELECT	@strWhereChild = @strWhereChild + 'AND sched.ScheduleID = @criScheduleID '

--Include in projection
IF @criOption = 2
	SELECT	@strWhere = @strWhere + 'AND sched.IncludeInProjection = 1 '

--Include in family fee
IF @criOption = 3
	SELECT	@strWhere = @strWhere + 'AND sched.IncludeInFamilyFee = 1 '

--Provider ID
--Cannot be included in standard WHERE clause for family insert - put in separate variable
IF @criProviderID <> 0
	SELECT	@strWhereChild = @strWhereChild + 'AND sched.ProviderID = @criProviderID '

--Provider service dates
IF @optProviderServiceStartDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (prv.ServiceStartDate <= @criStopDate '
		SELECT	@strWhere = @strWhere + 'OR prv.ServiceStartDate IS NULL) '
	END

IF @optProviderServiceStopDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (prv.ServiceStopDate >= @criStartDate '
		SELECT	@strWhere = @strWhere + 'OR prv.ServiceStopDate IS NULL) '
	END

--Provider on hold
IF @optProviderOnHold <> 0
	SELECT	@strWhere = @strWhere + 'AND prv.HoldPayments = 0 '

--Provider denial date
IF @optProviderDenialDate <> 0
	BEGIN
		SELECT	@strWhere = @strWhere + 'AND (prv.Denied = 0 '
		SELECT	@strWhere = @strWhere + 'OR prv.DenialDate >= @criStartDate) '
	END

--Program ID
--Cannot be included in standard WHERE clause for family insert - put in separate variable
IF @criProgramID <> 0
	BEGIN
		IF @optProgramSource = 1 --Child level
			BEGIN
				SELECT	@strWhereChild = @strWhereChild + 'AND cp.ProgramID = @criProgramID '

				SELECT	@strWhereChild = @strWhereChild + 'AND (cp.StartDate IS NULL '
				SELECT	@strWhereChild = @strWhereChild + 'OR cp.StartDate <= @criStopDate) '

				SELECT	@strWhereChild = @strWhereChild + 'AND (cp.StopDate IS NULL '
				SELECT	@strWhereChild = @strWhereChild + 'OR cp.StopDate >= @criStartDate) '
			END

		IF @optProgramSource = 2 --Schedule detail level
			SELECT	@strWhereChild = @strWhereChild + 'AND det.ProgramID = @criProgramID '
	END

--Specialist ID
IF @criSpecialistID <> 0
	SELECT	@strWhere = @strWhere + 'AND fs.SpecialistID = @criSpecialistID '

--Division ID
IF @criDivisionID <> 0
	SELECT	@strWhere = @strWhere + 'AND fam.DivisionID = @criDivisionID '

--Include/exclude children with attendance data
IF @criIncludeAttendance = 0
	--Exclude children with attendance data
	SELECT	@strWhere = @strWhere + 'AND att.ChildID IS NULL '

IF @criIncludeAttendance = 1
	--Include only children with attendance data
	--Putting date check here ensures that there are attendance records
	SELECT	@strWhere = @strWhere + 'AND att.AttendanceDate BETWEEN @criStartDate AND @criStopDate '

IF @optIncludeFamilyFees = 1
	BEGIN
		--Generate list of all families in calculation
		--INSERT clause
		IF @criOption = 4
			BEGIN
				INSERT #tmpFamilyAdjustmentList
					(FamilyID)
				SELECT	DISTINCT
						f.FamilyID
				FROM	tblAttendanceHistory ah (NOLOCK)
						JOIN tblAttendanceHistoryDetail ahd (NOLOCK)
							ON ah.AttendanceHistoryID = ahd.AttendanceHistoryID
						JOIN tblChild c (NOLOCK)
							ON ah.ChildID = c.ChildID
						JOIN tblFamily f (NOLOCK)
							ON c.FamilyID = f.FamilyID
						JOIN tblChild c2 (NOLOCK)
							ON f.FamilyID = c2.FamilyID
						JOIN tblSchedule s (NOLOCK)
							ON c2.ChildID = s.ChildID
						JOIN tblScheduleDetail det (NOLOCK) 
							ON s.ScheduleID = det.ScheduleID 
						JOIN tblProgram p (NOLOCK)
							ON ahd.ProgramID = p.ProgramID
						LEFT JOIN tlnkFamilySpecialist fs (NOLOCK)
							ON.f.FamilyID = fs.FamilyID
				WHERE	ah.AttendanceDate >= @criStartDate
						AND ah.AttendanceDate <= @criStopDate
						AND (s.StartDate IS NULL 
							OR s.StartDate <= @criStopDate) 
						AND (s.StopDate IS NULL 
							OR s.StopDate >= @criStartDate) 
						AND (f.DivisionID = @criDivisionID 
							OR @criDivisionID = 0)
						AND (f.FamilyID = @criFamilyID
							OR @criFamilyID = 0)
						AND (c2.ChildID = @criChildID
							OR @criChildID = 0)
						AND (ahd.ProgramID = @criProgramID
							OR @criProgramID = 0)
						AND (ah.ProviderID = @criProviderID
							OR @criProviderID = 0)
						AND (fs.SpecialistID = @criSpecialistID
							AND fs.PrimarySpecialist = 1
							OR @criSpecialistID = 0)
						AND (@criProgramGroupID = 0 
							OR ahd.ProgramID IN	(SELECT	pgp.ProgramID
												FROM	tlnkProgramGroupProgram pgp (NOLOCK)
														JOIN tlkpProgramGroup pg (NOLOCK)
															ON pgp.ProgramGroupID = pg.ProgramGroupID
												WHERE	pg.ProgramGroupID = @criProgramGroupID))
						AND ((@criVariable = 1 
								AND det.Variable = @criVariable)
							OR (@criVariable = 2
								AND det.Variable = 0)
							OR (@criVariable = 0))
						AND p.FamilyFeeSchedule <> 1 

				INSERT #tmpFamilyBilledList
					(FamilyID)
				SELECT	DISTINCT
						f.FamilyID
				FROM	tblARLedger ar (NOLOCK)
						JOIN tblFamily f (NOLOCK)
							ON ar.FamilyID = f.FamilyID
						JOIN tblChild c (NOLOCK)
							ON f.FamilyID = c.FamilyID
						JOIN tblSchedule s (NOLOCK)
							ON c.ChildID = s.ChildID
						JOIN tblScheduleDetail det (NOLOCK) 
							ON s.ScheduleID = det.ScheduleID 
						JOIN tblProgram p (NOLOCK)
							ON ar.ProgramID = p.ProgramID
						LEFT JOIN tlnkFamilySpecialist fs (NOLOCK)
							ON.f.FamilyID = fs.FamilyID
				WHERE	ar.StartDate >= @criStartDate
						AND ar.StartDate <= @criStopDate
						AND ar.StopDate >= @criStartDate
						AND ar.StopDate <= @criStopDate
						AND (s.StartDate IS NULL 
							OR s.StartDate <= @criStopDate) 
						AND (s.StopDate IS NULL 
							OR s.StopDate >= @criStartDate) 
						AND (f.DivisionID = @criDivisionID 
							OR @criDivisionID = 0)
						AND (f.FamilyID = @criFamilyID
							OR @criFamilyID = 0)
						AND (c.ChildID = @criChildID
							OR @criChildID = 0)
						AND (ar.ProgramID = @criProgramID
							OR @criProgramID = 0)
						AND (ar.ProviderID = @criProviderID
							OR @criProviderID = 0)
						AND (fs.SpecialistID = @criSpecialistID
							AND fs.PrimarySpecialist = 1
							OR @criSpecialistID = 0)
						AND (@criProgramGroupID = 0 
							OR ar.ProgramID IN	(SELECT	pgp.ProgramID
												FROM	tlnkProgramGroupProgram pgp (NOLOCK)
														JOIN tlkpProgramGroup pg (NOLOCK)
															ON pgp.ProgramGroupID = pg.ProgramGroupID
												WHERE	pg.ProgramGroupID = @criProgramGroupID))
						AND ((@criVariable = 1 
								AND det.Variable = @criVariable)
							OR (@criVariable = 2
								AND det.Variable = 0)
							OR (@criVariable = 0))
						AND p.FamilyFeeSchedule <> 1 				
			END
		ELSE
			BEGIN		
				SELECT	@strFamilyInsert = 'INSERT #tmpFamilyList '
				SELECT	@strFamilyInsert = @strFamilyInsert + '(FamilyID) '

				--SELECT clause
				SELECT	@strFamilySelect = 'SELECT DISTINCT '
				SELECT	@strFamilySelect = @strFamilySelect + 'chi.FamilyID '

				--FROM clause
				--Reuse standard FROM clause

				--WHERE clause
				--Reuse standard WHERE clause and append child-specific criteria

				SELECT	@strSQL = @strFamilyInsert + @strFamilySelect + @strFrom + @strWhere + @strWhereChild + @strOption

				EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
											@criStopDate DATETIME,
											@criFamilyID INT,
											@criChildID INT,
											@criScheduleID INT,
											@criProviderID INT,
											@criProgramID INT,
											@criSpecialistID INT,
											@criDivisionID INT',
											@criStartDate,
											@criStopDate,
											@criFamilyID,
											@criChildID,
											@criScheduleID,
											@criProviderID,
											@criProgramID,
											@criSpecialistID,
											@criDivisionID

			
				IF @criDebug = 1
					PRINT 'List of all families in calculation generated'

				--Insert schedules for these families into temp table
				--INSERT clause
				--Reuse standard INSERT clause

				--SELECT clause
				--Reuse standard SELECT clause

				--FROM clause
				--Reuse standard FROM clause with the addition of the family list
				SELECT	@strFrom = @strFrom + 'JOIN #tmpFamilyList famlist (NOLOCK) '
				SELECT	@strFrom = @strFrom + 'ON chi.FamilyID = famlist.FamilyID '

				--WHERE clause
				--Reuse standard WHERE clause

				SELECT	@strSQL = @strInsert + @strSelect + @strFrom + @strWhere + @strOption

				EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
											@criStopDate DATETIME,
											@criFamilyID INT,
											@criChildID INT,
											@criScheduleID INT,
											@criProviderID INT,
											@criProgramID INT,
											@criSpecialistID INT,
											@criDivisionID INT',
											@criStartDate,
											@criStopDate,
											@criFamilyID,
											@criChildID,
											@criScheduleID,
											@criProviderID,
											@criProgramID,
											@criSpecialistID,
											@criDivisionID
			END
	END
/* If family fees are not calculated, don't need to calculate
care for entire families.  Just pull schedules meeting
specified criteria */
ELSE
	BEGIN
		--INSERT clause
		--Reuse standard INSERT clause

		--SELECT clause
		--Reuse standard SELECT clause

		--FROM clause
		--Reuse standard FROM clause

		--WHERE clause
		--Reuse standard WHERE clause and append child-specific criteria

		SELECT	@strSQL = @strInsert + @strSelect + @strFrom + @strWhere + @strWhereChild + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME,
									@criFamilyID INT,
									@criChildID INT,
									@criScheduleID INT,
									@criProviderID INT,
									@criProgramID INT,
									@criSpecialistID INT,
									@criDivisionID INT',
									@criStartDate,
									@criStopDate,
									@criFamilyID,
									@criChildID,
									@criScheduleID,
									@criProviderID,
									@criProgramID,
									@criSpecialistID,
									@criDivisionID
	END

--Set initial schedule start/stop dates
UPDATE	#tmpScheduleCopyInitial
SET		StartDate =	CASE
						WHEN StartDate IS NULL OR StartDate < @criStartDate
							THEN @criStartDate
						ELSE StartDate
					END,
		StopDate =	CASE
						WHEN StopDate IS NULL OR StopDate > @criStopDate
							THEN @criStopDate
						ELSE StopDate
					END
OPTION	(KEEP PLAN)

--If ignoring schedule stop date, set stop date to end of calc period
IF @optScheduleStopDate = 0
	BEGIN
		--Find latest stop date for each child/provider combo
		--Note that for schedules stopping after the calc period end date
		--as well as schedules with no stop date, the stop date has been set
		--to the calc period end date
		INSERT	#tmpLatestStopDate
			(ChildID,
			ProviderID,
			StopDate)
		SELECT		ChildID,
					ProviderID,
					MAX(StopDate)
		FROM		#tmpScheduleCopyInitial (NOLOCK)
		GROUP BY	ChildID,
					ProviderID
		OPTION		(KEEP PLAN)

		--Re-insert schedule information (marking it as extended) for all schedules
		--matching the stop date found above (for each child/provider combo)
		INSERT	#tmpScheduleCopyInitial
			(ScheduleID,
			ChildID,
			ProviderID,
			ClassroomID,
			FamilyID,
			ExtendedSchedule,
			StartDate,
			StopDate,
			SiblingDiscount,
			WeeklyHoursRegular,
			WeeklyHoursVacation,
			PrimaryProvider,
			PayFamily,
			SpecialNeedsRMRMultiplier,
			FamilyFirstServedDate,
			FamilyCertStartDate,
			FamilyCertStopDate,
			FamilyTermDate,
			FamilyCalWorksCashAidTermDate,
			FamilyCalWorksIneligibilityDate,
			FamilyCalWorksStage1StartDate,
			FamilyCalWorksStage1StopDate,
			FamilyCalWorksStage2StartDate,
			FamilyCalWorksStage2StopDate,
			FamilyCalWorksStage3StartDate,
			FamilyCalWorksStage3StopDate,
			ChildFirstEnrolled,
			ChildTermDate,
			ProviderServiceStartDate,
			ProviderServiceStopDate,
			ProviderDenied,
			ProviderDenialDate)
		SELECT	sched.ScheduleID,
				sched.ChildID,
				sched.ProviderID,
				sched.ClassroomID,
				sched.FamilyID,
				1,
				DATEADD(DAY, 1, sched.StopDate),
				@criStopDate,
				sched.SiblingDiscount,
				sched.WeeklyHoursRegular,
				sched.WeeklyHoursVacation,
				sched.PrimaryProvider,
				sched.PayFamily,
				sched.SpecialNeedsRMRMultiplier,
				sched.FamilyFirstServedDate,
				sched.FamilyCertStartDate,
				sched.FamilyCertStopDate,
				sched.FamilyTermDate,
				sched.FamilyCalWorksCashAidTermDate,
				sched.FamilyCalWorksIneligibilityDate,
				sched.FamilyCalWorksStage1StartDate,
				sched.FamilyCalWorksStage1StopDate,
				sched.FamilyCalWorksStage2StartDate,
				sched.FamilyCalWorksStage2StopDate,
				sched.FamilyCalWorksStage3StartDate,
				sched.FamilyCalWorksStage3StopDate,
				sched.ChildFirstEnrolled,
				sched.ChildTermDate,
				sched.ProviderServiceStartDate,
				sched.ProviderServiceStopDate,
				sched.ProviderDenied,
				sched.ProviderDenialDate
		FROM	#tmpScheduleCopyInitial sched
				JOIN #tmpLatestStopDate lsdt
					ON sched.ChildID = lsdt.ChildID
						AND sched.ProviderID = lsdt.ProviderID
						AND sched.StopDate = lsdt.StopDate
		WHERE	sched.StopDate < @criStopDate
		OPTION	(KEEP PLAN)
	END

IF @criDebug = 1
	EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

IF @criOption = 4 
	BEGIN
		INSERT #tmpAttendanceCopyInitial
			(ChildID,
			ProviderID,
			ClassroomID,
			ProgramID,
			FamilyID,
			AttendanceDate,
			AttendanceHours,
			DayOfWeek,
			WeekStart,
			WeekStop,
			MonthStart,
			MonthStop)
		SELECT	ah.ChildID,
				ah.ProviderID,
				ahd.ClassroomID,
				ahd.ProgramID,
				f.FamilyID,
				ah.AttendanceDate,
				ahd.Hours,
				cal.DayOfWeek,
				cal.WeekStart,
				cal.WeekStop,
				cal.MonthStart,
				cal.MonthStop
		FROM	tblAttendanceHistory ah (NOLOCK)
				JOIN tblAttendanceHistoryDetail ahd (NOLOCK)
					ON ah.AttendanceHistoryID = ahd.AttendanceHistoryID
				JOIN tblChild c (NOLOCK)
					ON ah.ChildID = c.ChildID
				JOIN tblFamily f (NOLOCK)
					ON c.FamilyID = f.FamilyID
				JOIN #tmpFamilyAdjustmentList fee (NOLOCK)
					ON f.FamilyID = fee.FamilyID
				JOIN #tmpCalendar cal (NOLOCK)
					ON ah.AttendanceDate = cal.CalendarDate
		WHERE	ah.AttendanceDate >= @criStartDate
				AND ah.AttendanceDate <= @criStopDate
				AND (f.DivisionID = @criDivisionID 
					OR @criDivisionID = 0)
				AND (f.FamilyID = @criFamilyID
					OR @criFamilyID = 0)

		INSERT 	 #tmpBilledFees
			(FamilyID,
			ChildID,
			ProgramID,
 			InvoiceID,
 			ProviderID,
			StartDate,
			StopDate,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			UserID)
		SELECT		ar.FamilyID,
					ar.ChildID,
					ar.ProgramID,
					ar.InvoiceID,
					ar.ProviderID,
					ar.StartDate,
					ar.StopDate,
					ar.PaymentTypeID,
					ar.RateTypeID,
					ar.CareTimeID,
					ar.Rate,
					SUM(ar.Units) AS Units,
					SUM(ar.Total) AS Total,
					ar.UserID
		FROM		tblARLedger ar
					JOIN tblFamily f
						ON ar.FamilyID = f.FamilyID
					JOIN #tmpFamilyBilledList bill 
						ON ar.FamilyID = bill.FamilyID
		WHERE		ar.StartDate >= @criStartDate
					AND ar.StartDate <= @criStopDate
					AND ar.StopDate >= @criStartDate
					AND ar.StopDate <= @criStopDate
					AND (f.DivisionID = @criDivisionID 
						OR @criDivisionID = 0)
					AND (f.FamilyID = @criFamilyID
						OR @criFamilyID = 0)
					AND ar.Void = 0
		GROUP BY 	ar.FamilyID,
					ar.ChildID,
					ar.ProgramID,
					ar.InvoiceID,
					ar.ProviderID,
					ar.StartDate,
					ar.StopDate,
					ar.PaymentTypeID,
					ar.RateTypeID,
					ar.CareTimeID,
					ar.Rate,
					ar.UserID
		HAVING		SUM(ar.Total) <> 0

		DELETE	b
		FROM	#tmpBilledFees b
				LEFT JOIN	(SELECT	DISTINCT
									FamilyID,
									DATEPART(MONTH,AttendanceDate) as MonthDate
							FROM	#tmpAttendanceCopyInitial) sub
					ON b.FamilyID = sub.FamilyID
						AND DATEPART(MONTH, b.StartDate) = sub.MonthDate
		WHERE	sub.MonthDate IS NULL

		DELETE	a
		FROM	#tmpAttendanceCopyInitial a
				LEFT JOIN	(SELECT	DISTINCT
									b.FamilyID,
									DATEPART(MONTH, b.StartDate) as MonthDate
							FROM	#tmpBilledFees b) sub
					ON a.FamilyID = sub.FamilyID
						AND DATEPART(MONTH, a.AttendanceDate) = sub.MonthDate
		WHERE	sub.MonthDate IS NULL
	END

/* Loop through month by month */
WHILE @procStartDate <= @criStopDate
	BEGIN
		IF @criDebug = 1
			BEGIN
				PRINT	'Processing ' + CONVERT(VARCHAR, @procStartDate) + ' through ' + CONVERT(VARCHAR, @procStopDate)
				PRINT	''
			END

		/* Check whether projections have been cancelled */
		--Projection only
		IF @criOption = 2
			BEGIN
				SELECT	@procCancelled = Cancelled
				FROM	tblProjectionCancel (NOLOCK)

				IF @procCancelled = 1
					BEGIN
						IF @criDebug = 1
							PRINT 'Projections cancelled'

						RETURN
					END
			END

		/* Delete temp table data */
		SELECT	@procDebugMessage = 'Temp table data deletion'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Family list
		TRUNCATE TABLE #tmpFamilyList
		TRUNCATE TABLE #tmpFamilyAdjustmentList
		TRUNCATE TABLE #tmpFamilyBilledList
		
		--Schedule program (used for fixed fees)
		TRUNCATE TABLE #tmpScheduleProgram

		--Schedule
		TRUNCATE TABLE #tmpScheduleCopy

		--Attendance for Family Fee Adjustments
		TRUNCATE TABLE #tmpAttendanceCopy
		TRUNCATE TABLE #tmpBilledFeesCopy

		--Day-by-day schedule
		TRUNCATE TABLE #tmpScheduleDayByDay

		--Schedule detail
		TRUNCATE TABLE #tmpScheduleDetail

		--Schedule detail day
		TRUNCATE TABLE #tmpScheduleDetailDay

		--Day-by-day schedule detail
		TRUNCATE TABLE #tmpDayByDay

		--List of families paid directly (excluded from family fee)
		TRUNCATE TABLE #tmpPayFamily

		--Family fee rates
		TRUNCATE TABLE #tmpFeeRates

		--Family fee
		TRUNCATE TABLE #tmpFamilyFee

		--Rate book storage by day
		TRUNCATE TABLE #tmpRateBookByDay
		
		--School day by day
		TRUNCATE TABLE #tmpChildSchool
		
		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Insert schedules to temp table */
		SELECT	@procDebugMessage = 'Schedule insertion into temp table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		/* Of the schedules which were valid at some point during the calc period
		(found before the beginning of the loop) find the ones which are valid for
		the current month */
		--Date criteria need to be re-checked here; however, all checks on the 
		--various IDs (family, child, etc.) were already performed earlier
		--INSERT clause
		SELECT	@strInsert = 'INSERT #tmpScheduleCopy '
		SELECT	@strInsert = @strInsert + '(ScheduleID, '
		SELECT	@strInsert = @strInsert + 'ChildID, '
		SELECT	@strInsert = @strInsert + 'ProviderID, '
		SELECT	@strInsert = @strInsert + 'ClassroomID, '
		SELECT	@strInsert = @strInsert + 'FamilyID, '
		SELECT	@strInsert = @strInsert + 'ExtendedSchedule, '
		SELECT	@strInsert = @strInsert + 'StartDate, '
		SELECT	@strInsert = @strInsert + 'StopDate, '
		SELECT	@strInsert = @strInsert + 'SiblingDiscount, '
		SELECT	@strInsert = @strInsert + 'WeeklyHoursRegular, '
		SELECT	@strInsert = @strInsert + 'WeeklyHoursVacation, '
		SELECT	@strInsert = @strInsert + 'PrimaryProvider, '
		SELECT	@strInsert = @strInsert + 'PayFamily, '
		SELECT	@strInsert = @strInsert + 'SpecialNeedsRMRMultiplier, '
		SELECT	@strInsert = @strInsert + 'FamilyFirstServedDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCertStartDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCertStopDate, '
		SELECT	@strInsert = @strInsert + 'FamilyTermDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksCashAidTermDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksIneligibilityDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage1StartDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage1StopDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage2StartDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage2StopDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage3StartDate, '
		SELECT	@strInsert = @strInsert + 'FamilyCalWorksStage3StopDate, '
		SELECT	@strInsert = @strInsert + 'ChildFirstEnrolled, '
		SELECT	@strInsert = @strInsert + 'ChildTermDate, '
		SELECT	@strInsert = @strInsert + 'ProviderServiceStartDate, '
		SELECT	@strInsert = @strInsert + 'ProviderServiceStopDate, '
		SELECT	@strInsert = @strInsert + 'ProviderDenied, '
		SELECT	@strInsert = @strInsert + 'ProviderDenialDate) '

		--SELECT clause
		SELECT	@strSelect = 'SELECT DISTINCT '
		SELECT	@strSelect = @strSelect + 'sched.ScheduleID, '
		SELECT	@strSelect = @strSelect + 'sched.ChildID, '
		SELECT	@strSelect = @strSelect + 'sched.ProviderID, '
		SELECT	@strSelect = @strSelect + 'sched.ClassroomID, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyID, '
		SELECT	@strSelect = @strSelect + 'sched.ExtendedSchedule, '
		SELECT	@strSelect = @strSelect + 'sched.StartDate, '
		SELECT	@strSelect = @strSelect + 'sched.StopDate, '
		SELECT	@strSelect = @strSelect + 'sched.SiblingDiscount, '
		SELECT	@strSelect = @strSelect + 'sched.WeeklyHoursRegular, '
		SELECT	@strSelect = @strSelect + 'sched.WeeklyHoursVacation, '
		SELECT	@strSelect = @strSelect + 'sched.PrimaryProvider, '
		SELECT	@strSelect = @strSelect + 'sched.PayFamily, '
		SELECT	@strSelect = @strSelect + 'sched.SpecialNeedsRMRMultiplier, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyFirstServedDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCertStartDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCertStopDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyTermDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksCashAidTermDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksIneligibilityDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage1StartDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage1StopDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage2StartDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage2StopDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage3StartDate, '
		SELECT	@strSelect = @strSelect + 'sched.FamilyCalWorksStage3StopDate, '
		SELECT	@strSelect = @strSelect + 'sched.ChildFirstEnrolled, '
		SELECT	@strSelect = @strSelect + 'sched.ChildTermDate, '
		SELECT	@strSelect = @strSelect + 'sched.ProviderServiceStartDate, '
		SELECT	@strSelect = @strSelect + 'sched.ProviderServiceStopDate, '
		SELECT	@strSelect = @strSelect + 'sched.ProviderDenied, '
		SELECT	@strSelect = @strSelect + 'sched.ProviderDenialDate '

		--FROM clause
		--Schedule
		SELECT	@strFrom = 'FROM #tmpScheduleCopyInitial sched (NOLOCK) '

		--WHERE clause
		SELECT	@strWhere = ''

		--Service dates
		IF @optScheduleStartDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.StartDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.StartDate <= @criStopDate) '
			END

		IF @optScheduleStopDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.StopDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.StopDate >= @criStartDate) '
			END

		--First served date
		IF @optFamilyFirstServedDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyFirstServedDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyFirstServedDate <= @criStopDate) '
			END

		--Cert dates
		IF @optFamilyCertStartDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyCertStartDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCertStartDate <= @criStopDate) '
			END

		IF @optFamilyCertStopDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyCertStopDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCertStopDate >= @criStartDate) '
			END

		--Family term date
		IF @optFamilyTermDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyTermDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyTermDate >= @criStartDate) '
			END

		--CalWORKs dates
		IF @optFamilyCalWorksStopDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyCalWorksStage1StopDate >= @criStartDate '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksStage1StopDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksStage2StartDate IS NOT NULL) '

				SELECT	@strWhere = @strWhere + 'AND (sched.FamilyCalWorksStage2StopDate >= @criStartDate '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksStage2StopDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksStage3StartDate IS NOT NULL) '

				SELECT	@strWhere = @strWhere + 'AND (sched.FamilyCalWorksStage3StopDate >= @criStartDate '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksStage3StopDate IS NULL) '
			END

		--Cash aid term date
		IF @optFamilyCalWorksCashAidTermDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyCalWorksCashAidTermDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksCashAidTermDate >= @criStartDate) '
			END

		--Ineligibility date
		IF @optFamilyCalWorksIneligibilityDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.FamilyCalWorksIneligibilityDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.FamilyCalWorksIneligibilityDate >= @criStartDate) '
			END

		--First enrolled date
		IF @optChildFirstEnrolledDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.ChildFirstEnrolled IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.ChildFirstEnrolled <= @criStopDate) '
			END

		--Child term date
		IF @optChildTermDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.ChildTermDate IS NULL '
				SELECT	@strWhere = @strWhere + 'OR sched.ChildTermDate >= @criStartDate) '
			END

		--LOA
		--LOA check is removed from initial checking because
		--there is now a start and stop date, making the
		--check trickier

		--Provider service dates
		IF @optProviderServiceStartDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.ProviderServiceStartDate <= @criStopDate '
				SELECT	@strWhere = @strWhere + 'OR sched.ProviderServiceStartDate IS NULL) '
			END

		IF @optProviderServiceStopDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.ProviderServiceStopDate >= @criStartDate '
				SELECT	@strWhere = @strWhere + 'OR sched.ProviderServiceStopDate IS NULL) '
			END

		--Provider denial date
		IF @optProviderDenialDate <> 0
			BEGIN
				IF @strWhere = ''
					SELECT	@strWhere = 'WHERE '
				ELSE
					SELECT	@strWhere = @strWhere + 'AND '

				SELECT	@strWhere = @strWhere + '(sched.ProviderDenied = 0 '
				SELECT	@strWhere = @strWhere + 'OR sched.ProviderDenialDate >= @criStartDate) '
			END

		SELECT	@strSQL = @strInsert + @strSelect + @strFrom + @strWhere + @strOption

		EXEC sp_executesql @strSQL,	N'@criStartDate DATETIME,
									@criStopDate DATETIME',
									@criStartDate,
									@criStopDate

		--Determine one program per schedule for fixed fees
		INSERT	#tmpScheduleProgram
			(ScheduleID,
			ProgramID)
		SELECT		s.ScheduleID,
					MAX(det.ProgramID) AS ProgramID
		FROM		#tmpScheduleCopy s (NOLOCK)
					JOIN tblScheduleDetail det (NOLOCK)
						ON s.ScheduleID = det.ScheduleID
		WHERE		det.ProgramID IS NOT NULL
		GROUP BY	s.ScheduleID
		OPTION		(KEEP PLAN)

		IF @criOption = 4 
			BEGIN
				INSERT #tmpAttendanceCopy
					(ChildID,
					ProviderID,
					ClassroomID,
					ProgramID,
					FamilyID,
					AttendanceDate,
					AttendanceHours,
					DayOfWeek,
					WeekStart,
					WeekStop,
					MonthStart,
					MonthStop)
				SELECT	a.ChildID,
						a.ProviderID,
						a.ClassroomID,
						a.ProgramID,
						a.FamilyID,
						a.AttendanceDate,
						a.AttendanceHours,
						a.DayOfWeek,
						a.WeekStart,
						a.WeekStop,
						a.MonthStart,
						a.MonthStop
				FROM	#tmpAttendanceCopyInitial a (NOLOCK)
				WHERE	a.AttendanceDate >= @criStartDate
						AND a.AttendanceDate <= @criStopDate

				INSERT 	 #tmpBilledFeesCopy
					(FamilyID,
					ChildID,
					ProgramID,
 					InvoiceID,
 					ProviderID,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total,
					UserID)
				SELECT		FamilyID,
							ChildID,
							ProgramID,
							InvoiceID,
							ProviderID,
							StartDate,
							StopDate,
							PaymentTypeID,
							RateTypeID,
							CareTimeID,
							Rate,
							Units,
							Total,
							UserID
				FROM		#tmpBilledFees 
				WHERE		StartDate >= @criStartDate
							AND StartDate <= @criStopDate
							AND StopDate >= @criStartDate
							AND StopDate <= @criStopDate
				
			END

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Set start and stop dates for schedule to criteria,
		if they do not already fall within range */
		SELECT	@procDebugMessage = 'Initial schedule date setting'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Start date
		UPDATE	#tmpScheduleCopy
		SET		StartDate = @procStartDate
		WHERE	@procStartDate > StartDate
				OR StartDate IS NULL
		OPTION	(KEEP PLAN)

		--Stop date
		UPDATE	#tmpScheduleCopy
		SET		StopDate = @procStopDate
		WHERE	@procStopDate < StopDate
				OR StopDate IS NULL
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Modify dates */
		SELECT	@procDebugMessage = 'Schedule date modification'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Enter projection error data when dates are modified
		--(for projection only)

		/* Start date modifications by family */
		--First served date
		IF @optFamilyFirstServedDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyFirstServedDate,
									'F',
									'Family First Served Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyFirstServedDate >= sched.StartDate
									AND (cp.StartDate <= sched.FamilyFirstServedDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyFirstServedDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyFirstServedDate,
									'F',
									'Family First Served Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyFirstServedDate >= sched.StartDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StartDate = FamilyFirstServedDate
				WHERE	FamilyFirstServedDate > StartDate
				OPTION	(KEEP PLAN)
			END

		--Cert start
		IF @optFamilyCertStartDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCertStartDate,
									'C',
									'Family Cert Start Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyCertStartDate >= sched.StartDate
									AND (cp.StartDate <= sched.FamilyCertStartDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyCertStartDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCertStartDate,
									'C',
									'Family Cert Start Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyCertStartDate >= sched.StartDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StartDate = FamilyCertStartDate
				WHERE	FamilyCertStartDate > StartDate
				OPTION	(KEEP PLAN)
			END

		/* Stop date modifications by family */
		--Cert stop
		IF @optFamilyCertStopDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCertStopDate,
									'C',
									'Family Cert Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyCertStopDate <= sched.StopDate
									AND (cp.StartDate <= sched.FamilyCertStopDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyCertStopDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCertStopDate,
									'C',
									'Family Cert Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyCertStopDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END
				UPDATE	#tmpScheduleCopy
				SET		StopDate = FamilyCertStopDate
				WHERE	FamilyCertStopDate < StopDate
				OPTION	(KEEP PLAN)
			END

		--Term date
		IF @optFamilyTermDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyTermDate,
									'T',
									'Family Term Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyTermDate <= sched.StopDate
									AND (cp.StartDate <= sched.FamilyTermDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyTermDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyTermDate,
									'T',
									'Family Term Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyTermDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = FamilyTermDate
				WHERE	FamilyTermDate < StopDate
				OPTION	(KEEP PLAN)
			END

		--CalWORKS stop date
		IF @optFamilyCalWorksStopDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									CASE
										WHEN sched.FamilyCalWorksStage1StopDate <= sched.StopDate
												AND sched.FamilyCalWorksStage2StartDate IS NULL
											THEN sched.FamilyCalWorksStage1StopDate
										WHEN sched.FamilyCalWorksStage2StopDate <= sched.StopDate
												AND sched.FamilyCalWorksStage3StartDate IS NULL
											THEN sched.FamilyCalWorksStage2StopDate
										WHEN sched.FamilyCalWorksStage3StopDate <= sched.StopDate
											THEN sched.FamilyCalWorksStage3StopDate
										ELSE sched.StopDate
									END,
									'W',
									'Family CalWORKs Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyCalWorksStage1StopDate <= sched.StopDate
										AND sched.FamilyCalWorksStage2StartDate IS NULL
										AND (cp.StartDate <= sched.FamilyCalWorksStage1StopDate
											OR cp.StartDate IS NULL)
										AND (cp.StopDate >= sched.FamilyCalWorksStage1StopDate
											OR cp.StopDate IS NULL)
									OR sched.FamilyCalWorksStage2StopDate <= sched.StopDate
										AND sched.FamilyCalWorksStage3StartDate IS NULL
										AND (cp.StartDate <= sched.FamilyCalWorksStage2StopDate
											OR cp.StartDate IS NULL)
										AND (cp.StopDate >= sched.FamilyCalWorksStage2StopDate
											OR cp.StopDate IS NULL)
									OR sched.FamilyCalWorksStage3StopDate <= sched.StopDate
										AND (cp.StartDate <= sched.FamilyCalWorksStage3StopDate
											OR cp.StartDate IS NULL)
										AND (cp.StopDate >= sched.FamilyCalWorksStage3StopDate
											OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									CASE
										WHEN sched.FamilyCalWorksStage1StopDate <= sched.StopDate
												AND sched.FamilyCalWorksStage2StartDate IS NULL
											THEN sched.FamilyCalWorksStage1StopDate
										WHEN sched.FamilyCalWorksStage2StopDate <= sched.StopDate
												AND sched.FamilyCalWorksStage3StartDate IS NULL
											THEN sched.FamilyCalWorksStage2StopDate
										WHEN sched.FamilyCalWorksStage3StopDate <= sched.StopDate
											THEN sched.FamilyCalWorksStage3StopDate
										ELSE sched.StopDate
									END,
									'W',
									'Family CalWorks Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	(sched.FamilyCalWorksStage1StopDate <= sched.StopDate
											AND sched.FamilyCalWorksStage2StartDate IS NULL
										OR sched.FamilyCalWorksStage2StopDate <= sched.StopDate
											AND sched.FamilyCalWorksStage3StartDate IS NULL
										OR sched.FamilyCalWorksStage3StopDate <= sched.StopDate)
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate =	CASE
										WHEN FamilyCalWorksStage1StopDate < StopDate
												AND FamilyCalWorksStage2StartDate IS NULL
											THEN FamilyCalWorksStage1StopDate
										WHEN FamilyCalWorksStage2StopDate < StopDate
												AND FamilyCalWorksStage3StartDate IS NULL
											THEN FamilyCalWorksStage2StopDate
										WHEN FamilyCalWorksStage3StopDate < StopDate
											THEN FamilyCalWorksStage3StopDate
										ELSE StopDate
									END
				WHERE	FamilyCalWorksStage1StopDate <= StopDate
							AND FamilyCalWorksStage2StartDate IS NULL
						OR FamilyCalWorksStage2StopDate <= StopDate
							AND FamilyCalWorksStage3StartDate IS NULL
						OR FamilyCalWorksStage3StopDate <= StopDate
				OPTION	(KEEP PLAN)
			END

		--CalWORKS cash aid term date
		IF @optFamilyCalWorksCashAidTermDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCalWorksCashAidTermDate,
									'W',
									'Family Cash Aid Term Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyCalWorksCashAidTermDate <= sched.StopDate
									AND (cp.StartDate <= sched.FamilyCalWorksCashAidTermDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyCalWorksCashAidTermDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCalWorksCashAidTermDate,
									'W',
									'Family Cash Aid Term Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyCalWorksCashAidTermDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = FamilyCalWorksCashAidTermDate
				WHERE	FamilyCalWorksCashAidTermDate < StopDate
				OPTION	(KEEP PLAN)
			END

		--CalWORKS ineligibility date
		IF @optFamilyCalWorksIneligibilityDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCalWorksIneligibilityDate,
									'W',
									'Family Ineligibility Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.FamilyCalWorksIneligibilityDate <= sched.StopDate
									AND (cp.StartDate <= sched.FamilyCalWorksIneligibilityDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.FamilyCalWorksIneligibilityDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.FamilyCalWorksIneligibilityDate,
									'W',
									'Family Ineligibility Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.FamilyCalWorksIneligibilityDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = FamilyCalWorksIneligibilityDate
				WHERE	FamilyCalWorksIneligibilityDate < StopDate
				OPTION	(KEEP PLAN)
			END

		/* Start date modifications by child */
		--First enrolled date
		IF @optChildFirstEnrolledDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ChildFirstEnrolled,
									'E',
									'Child Enrolled Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.ChildFirstEnrolled >= sched.StartDate
									AND (cp.StartDate <= sched.ChildFirstEnrolled
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.ChildFirstEnrolled
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ChildFirstEnrolled,
									'E',
									'Child Enrolled Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.ChildFirstEnrolled >= sched.StartDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StartDate = ChildFirstEnrolled
				WHERE	ChildFirstEnrolled > StartDate
				OPTION	(KEEP PLAN)
		END

		/* Stop date modifications by child */
		--Term date
		IF @optChildTermDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ChildTermDate,
									'T',
									'Child Term Date' 
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.ChildTermDate <= sched.StopDate
									AND (cp.StartDate <= sched.ChildTermDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.ChildTermDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ChildTermDate,
									'T',
									'Child Term Date' 
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.ChildTermDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = ChildTermDate
				WHERE	ChildTermDate < StopDate
				OPTION	(KEEP PLAN)
			END

		/* Start date modifications by provider */
		--Service start date
		IF @optProviderServiceStartDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderServiceStartDate,
									'PVS',
									'Provider Service Start Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.ProviderServiceStartDate >= sched.StartDate
									AND (cp.StartDate <= sched.ProviderServiceStartDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.ProviderServiceStartDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderServiceStartDate,
									'PVS',
									'Provider Service Start Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.ProviderServiceStartDate >= sched.StartDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StartDate = ProviderServiceStartDate
				WHERE	ProviderServiceStartDate > StartDate
				OPTION	(KEEP PLAN)
			END

		/* Stop date modifications by provider */
		--Service stop date
		IF @optProviderServiceStopDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderServiceStopDate,
									'PVS',
									'Provider Service Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.ProviderServiceStopDate <= sched.StopDate
									AND (cp.StartDate <= sched.ProviderServiceStopDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.ProviderServiceStopDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderServiceStopDate,
									'PVS',
									'Provider Service Stop Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.ProviderServiceStopDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = ProviderServiceStopDate
				WHERE	ProviderServiceStopDate < StopDate
				OPTION	(KEEP PLAN)
			END

		--Denial date
		IF @optProviderDenialDate = 1
			BEGIN
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderDenialDate,
									'PVD',
									'Provider Denied'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	sched.ProviderDenied = 1
									AND sched.ProviderDenialDate <= sched.StopDate
									AND (cp.StartDate <= sched.ProviderDenialDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= sched.ProviderDenialDate
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									sched.FamilyID,
									sched.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									sched.ProviderDenialDate,
									'PVD',
									'Provider Denied'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	sched.ProviderDenied = 1
									AND sched.ProviderDenialDate <= sched.StopDate
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				UPDATE	#tmpScheduleCopy
				SET		StopDate = ProviderDenialDate
				WHERE	ProviderDenied = 1
						AND ProviderDenialDate < StopDate
				OPTION	(KEEP PLAN)
			END

		--Hold payments
		--Eliminated in initial schedule insert above

		/* Program dates -- only insert error for start and stop */
		IF @criOption = 2
			IF @optProgramSource = 1 --Child level
				BEGIN
					--Start date
					INSERT	#tmpError
						(FamilyID,
						ChildID,
						ProgramID,
						ScheduleID,
						ProviderID,
						ErrorDate,
						ErrorCode,
						ErrorDesc)
					SELECT	DISTINCT
							tmp.FamilyID,
							cp.ChildID,
							cp.ProgramID,
							tmp.ScheduleID,
							tmp.ProviderID,
							cp.StartDate,
							'PGS',
							'Program Start Date'
					FROM	#tmpScheduleCopy tmp (NOLOCK)
							JOIN tlnkChildProgram cp (NOLOCK)
								ON tmp.ChildID = cp.ChildID
					WHERE	cp.StartDate BETWEEN @procStartDate AND @procStopDate
					OPTION	(KEEP PLAN)

					--Stop date
					INSERT	#tmpError
						(FamilyID,
						ChildID,
						ProgramID,
						ScheduleID,
						ProviderID,
						ErrorDate,
						ErrorCode,
						ErrorDesc)
					SELECT	DISTINCT
							tmp.FamilyID,
							cp.ChildID,
							cp.ProgramID,
							tmp.ScheduleID,
							tmp.ProviderID,
							cp.StopDate,
							'TX',
							'Program Stop Date'
					FROM	#tmpScheduleCopy tmp (NOLOCK)
							JOIN tlnkChildProgram cp (NOLOCK)
								ON tmp.ChildID = cp.ChildID
					WHERE	cp.StopDate BETWEEN @procStartDate AND @procStopDate
					OPTION	(KEEP PLAN)
			END

		IF @optProgramSource = 2 --Schedule detail level
			BEGIN
				--Start date
				INSERT	#tmpError
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ProviderID,
					ErrorDate,
					ErrorCode,
					ErrorDesc)
				SELECT	DISTINCT
						tmp.FamilyID,
						sched.ChildID,
						det.ProgramID,
						sched.ScheduleID,
						sched.ProviderID,
						sched.StartDate,
						'PGS',
						'Program Start Date'
				FROM	#tmpScheduleCopy tmp (NOLOCK)
						JOIN tblSchedule sched (NOLOCK)
							ON tmp.ScheduleID = sched.ScheduleID
						JOIN tblScheduleDetail det (NOLOCK)
							ON sched.ScheduleID = det.ScheduleID
				WHERE	sched.StartDate BETWEEN @procStartDate AND @procStopDate
						AND det.ProgramID IS NOT NULL
						AND NOT EXISTS	(SELECT	prog.ScheduleID
										FROM	tblSchedule prog (NOLOCK)
												JOIN tblScheduleDetail progdet (NOLOCK)
													ON prog.ScheduleID = progdet.ScheduleID
										WHERE	prog.ChildID = sched.ChildID
												AND progdet.ProgramID = det.ProgramID
												AND (prog.StartDate <= DATEADD(DAY, -1, sched.StartDate)
													OR prog.StartDate IS NULL)
												AND (prog.StopDate >= DATEADD(DAY, -1, sched.StartDate)
													OR prog.StopDate IS NULL))
				OPTION	(KEEP PLAN)

				--Stop date
				INSERT	#tmpError
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ProviderID,
					ErrorDate,
					ErrorCode,
					ErrorDesc)
				SELECT	DISTINCT
						tmp.FamilyID,
						sched.ChildID,
						det.ProgramID,
						sched.ScheduleID,
						sched.ProviderID,
						sched.StopDate,
						'TX',
						'Program Stop Date'
				FROM	#tmpScheduleCopy tmp (NOLOCK)
						JOIN tblSchedule sched (NOLOCK)
							ON tmp.ScheduleID = sched.ScheduleID
						JOIN tblScheduleDetail det (NOLOCK)
							ON sched.ScheduleID = det.ScheduleID
				WHERE	sched.StopDate BETWEEN @procStartDate AND @procStopDate
						AND det.ProgramID IS NOT NULL
						AND NOT EXISTS	(SELECT	prog.ScheduleID
										FROM	tblSchedule prog (NOLOCK)
												JOIN tblScheduleDetail progdet (NOLOCK)
													ON prog.ScheduleID = progdet.ScheduleID
										WHERE	prog.ChildID = sched.ChildID
												AND progdet.ProgramID = det.ProgramID
												AND (prog.StartDate <= DATEADD(DAY, 1, sched.StopDate)
													OR prog.StartDate IS NULL)
												AND (prog.StopDate >= DATEADD(DAY, 1, sched.StopDate)
													OR prog.StopDate IS NULL))
				OPTION	(KEEP PLAN)
			END

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Delete invalid modified schedules */
		SELECT	@procDebugMessage = 'Invalid schedule removal'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		DELETE	#tmpScheduleCopy
		WHERE	StartDate > StopDate
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Populate day-by-day table for schedules */
		SELECT	@procDebugMessage = 'Day-by-day schedule table population'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		IF @optProgramSource = 1 --Child level
			INSERT	#tmpScheduleDayByDay
				(ScheduleID,
				ExtendedSchedule,
				CalendarDate,
				DayOfWeek,
				WeekStart,
				WeekStop,
				MonthStart,
				MonthStop,
				PaymentTypeCode)
			SELECT	sched.ScheduleID,
					sched.ExtendedSchedule,
					cal.CalendarDate,
					cal.DayOfWeek,
					cal.WeekStart,
					cal.WeekStop,
					cal.MonthStart,
					cal.MonthStop,
					@constPaymentTypeCode_Regular
			FROM	#tmpScheduleCopy sched (NOLOCK)
					JOIN #tmpCalendar cal (NOLOCK)
						ON sched.StartDate <= cal.CalendarDate
							AND sched.StopDate >= cal.CalendarDate
					JOIN tblChild c (NOLOCK)
						ON sched.ChildID = c.ChildID
					JOIN tblFamily f (NOLOCK)
						ON c.FamilyID = f.FamilyID
					LEFT JOIN tlnkChildProgram cp (NOLOCK)
						ON c.ChildID = cp.ChildID
					LEFT JOIN tblProgram prog (NOLOCK)
						ON cp.ProgramID = prog.ProgramID
					LEFT JOIN tlkpHoliday hol (NOLOCK)
						ON cal.CalendarDate = hol.HolidayDate
			WHERE	(@optHoliday = 1
						OR hol.HolidayID IS NULL
						--For full-fee/private families, check the option to charge for all holidays
						OR @criOption = 3
							AND prog.FamilyFeeSchedule = 1
							AND @optFullFeeChargeHolidayAbsenceNonOperation = 1)
					AND (cp.StartDate <= cal.CalendarDate
						OR cp.StartDate IS NULL)
					AND (cp.StopDate >= cal.CalendarDate
						OR cp.StopDate IS NULL)
			OPTION	(KEEP PLAN)

		IF @optProgramSource = 2 --Schedule detail level
			INSERT	#tmpScheduleDayByDay
				(ScheduleID,
				ExtendedSchedule,
				CalendarDate,
				DayOfWeek,
				WeekStart,
				WeekStop,
				MonthStart,
				MonthStop,
				PaymentTypeCode)
			SELECT	sched.ScheduleID,
					sched.ExtendedSchedule,
					cal.CalendarDate,
					cal.DayOfWeek,
					cal.WeekStart,
					cal.WeekStop,
					cal.MonthStart,
					cal.MonthStop,
					@constPaymentTypeCode_Regular
			FROM	#tmpScheduleCopy sched (NOLOCK)
					JOIN #tmpCalendar cal (NOLOCK)
						ON sched.StartDate <= cal.CalendarDate
							AND sched.StopDate >= cal.CalendarDate
					JOIN tblChild c (NOLOCK)
						ON sched.ChildID = c.ChildID
					JOIN tblFamily f (NOLOCK)
						ON c.FamilyID = f.FamilyID
					LEFT JOIN tblScheduleDetail det (NOLOCK)
						ON sched.ScheduleID = det.ScheduleID
					LEFT JOIN tlnkScheduleDetailDay sdd (NOLOCK)
						ON det.ScheduleDetailID = sdd.ScheduleDetailID
							AND cal.DayOfWeek = sdd.DayID
					LEFT JOIN tblProgram prog (NOLOCK)
						ON det.ProgramID = prog.ProgramID
					LEFT JOIN tlkpHoliday hol (NOLOCK)
						ON cal.CalendarDate = hol.HolidayDate
			WHERE	@optHoliday = 1
					OR hol.HolidayID IS NULL
					--For full-fee/private families, check the option to charge for all holidays
					OR @criOption = 3
						AND prog.FamilyFeeSchedule = 1
						AND @optFullFeeChargeHolidayAbsenceNonOperation = 1
			OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Remove LOA days */
		IF @optChildLOADate = 1
			BEGIN
				SELECT	@procDebugMessage = 'Deletion of LOA days'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Insert projection error
				IF @criOption = 2
					BEGIN
						IF @optProgramSource = 1 --Child level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									chi.FamilyID,
									chi.ChildID,
									cp.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									ISNULL(DATEADD(DAY, -1, loa.StartDate), sched.StartDate),
									'LOA',
									'Child LOA Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblChild chi (NOLOCK)
										ON sched.ChildID = chi.ChildID
									JOIN tlnkChildLOA loa (NOLOCK)
										ON chi.ChildID = loa.ChildID
									JOIN tlnkChildProgram cp (NOLOCK)
										ON sched.ChildID = cp.ChildID
							WHERE	(loa.StartDate <= sched.StopDate
										OR loa.StartDate IS NULL)
									AND (loa.StopDate >= sched.StartDate
										OR loa.StopDate IS NULL)
									AND (cp.StartDate <= ISNULL(DATEADD(DAY, -1, loa.StartDate), sched.StartDate)
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= ISNULL(DATEADD(DAY, -1, loa.StartDate), sched.StartDate)
										OR cp.StopDate IS NULL)
							OPTION	(KEEP PLAN)

						IF @optProgramSource = 2 --Schedule detail level
							INSERT	#tmpError
								(FamilyID,
								ChildID,
								ProgramID,
								ScheduleID,
								ProviderID,
								ErrorDate,
								ErrorCode,
								ErrorDesc)
							SELECT	DISTINCT
									chi.FamilyID,
									chi.ChildID,
									det.ProgramID,
									sched.ScheduleID,
									sched.ProviderID,
									ISNULL(DATEADD(DAY, -1, loa.StartDate), sched.StartDate),
									'LOA',
									'Child LOA Date'
							FROM	#tmpScheduleCopy sched (NOLOCK)
									JOIN tblChild chi (NOLOCK)
										ON sched.ChildID = chi.ChildID
									JOIN tlnkChildLOA loa (NOLOCK)
										ON chi.ChildID = loa.ChildID
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
							WHERE	(loa.StartDate <= sched.StopDate
										OR loa.StartDate IS NULL)
									AND (loa.StopDate >= sched.StartDate
										OR loa.StopDate IS NULL)
									AND det.ProgramID IS NOT NULL
							OPTION	(KEEP PLAN)
					END

				DELETE	tmp
				FROM	#tmpScheduleDayByDay tmp
						JOIN #tmpScheduleCopy sched (NOLOCK)
							ON tmp.ScheduleID = sched.ScheduleID
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
						JOIN tlnkChildLOA loa (NOLOCK)
							ON chi.ChildID = loa.ChildID
				WHERE	(tmp.CalendarDate <= loa.StopDate
							OR loa.StopDate IS NULL)
						AND (tmp.CalendarDate >= loa.StartDate
							OR loa.StartDate IS NULL)
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Populate schedule detail temp table */
		SELECT	@procDebugMessage = 'Schedule detail insertion into temp table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		INSERT	#tmpScheduleDetail
			(ScheduleDetailID,
			ScheduleID,
			PaymentTypeCode,
			Hours,
			WeeklyHours,
			Evening,
			Weekend,
			FixedFee,
			RateTypeID,
			FullTimeRate,
			PartTimeRate,
			FullFeeRate,
			RateBookDetailID,
			FullFeeRateBookDetailID,
			ProgramID,
			Breakfast,
			Lunch,
			Snack,
			Dinner)
		SELECT	DISTINCT
				det.ScheduleDetailID,
				det.ScheduleID,
				pt.PaymentTypeCode,
				det.Hours,
				det.WeeklyHours,
				det.Evening,
				det.Weekend,
				det.FixedFee,
				det.RateTypeID,
				CASE
					WHEN det.RateBookDetailID IS NULL
						THEN det.FullTimeRate
					ELSE NULL
				END,
				CASE
					WHEN det.RateBookDetailID IS NULL
						THEN det.PartTimeRate
					ELSE NULL
				END,
				CASE
					WHEN det.FullFeeRateBookDetailID IS NULL
						THEN det.FullFeeRate
					ELSE NULL
				END,
				det.RateBookDetailID,
				det.FullFeeRateBookDetailID,
				det.ProgramID,
				det.Breakfast,
				det.Lunch,
				det.Snack,
				det.Dinner
		FROM	tblScheduleDetail det (NOLOCK)
				JOIN tlkpPaymentType pt (NOLOCK)
					ON det.PaymentTypeID = pt.PaymentTypeID
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON det.ScheduleID = sched.ScheduleID
		WHERE	--Require program
				det.ProgramID IS NOT NULL
				OR @optProgramSource = 1
		OPTION	(KEEP PLAN)

		UPDATE	det
		SET		HoursPerWeek = sub.TotalHours
		FROM	#tmpScheduleDetail det
				JOIN	(SELECT		ScheduleID,
									PaymentTypeCode,
									ProgramID,
									RateTypeID,
									SUM(WeeklyHours) AS TotalHours
						FROM		#tmpScheduleDetail (NOLOCK)
						WHERE		WeeklyHours IS NOT NULL
						GROUP BY	ScheduleID,
									PaymentTypeCode,
									ProgramID,
									RateTypeID) sub
					ON det.ScheduleID = sub.ScheduleID
						AND det.PaymentTypeCode = sub.PaymentTypeCode
						AND ISNULL(det.ProgramID, 0) = ISNULL(sub.ProgramID, 0)
						AND det.RateTypeID = sub.RateTypeID
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Populate schedule detail days temp table */
		SELECT	@procDebugMessage = 'Schedule detail day insertion into temp table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		INSERT	#tmpScheduleDetailDay
			(ScheduleDetailID,
			DayID)
		SELECT	sdd.ScheduleDetailID,
				sdd.DayID
		FROM	#tmpScheduleDetail det (NOLOCK)
				JOIN tlnkScheduleDetailDay sdd (NOLOCK)
					ON det.ScheduleDetailID = sdd.ScheduleDetailID
		OPTION	(KEEP PLAN)

		UPDATE	dd
		SET		HoursPerDay = sub.TotalHours
		FROM	#tmpScheduleDetailDay dd
				JOIN #tmpScheduleDetail det (NOLOCK)
					ON dd.ScheduleDetailID = det.ScheduleDetailID
				JOIN	(SELECT		detsub.ScheduleID,
									detsub.PaymentTypeCode,
									detsub.ProgramID,
									detsub.RateTypeID,
									ddsub.DayID,
									SUM(detsub.Hours) AS TotalHours
						FROM		#tmpScheduleDetail detsub (NOLOCK)
									JOIN #tmpScheduleDetailDay ddsub (NOLOCK)
										ON detsub.ScheduleDetailID = ddsub.ScheduleDetailID
						WHERE		detsub.Hours IS NOT NULL
						GROUP BY	detsub.ScheduleID,
									detsub.PaymentTypeCode,
									detsub.ProgramID,
									detsub.RateTypeID,
									ddsub.DayID) sub
					ON det.ScheduleID = sub.ScheduleID
						AND det.PaymentTypeCode = sub.PaymentTypeCode
						AND ISNULL(det.ProgramID, 0) = ISNULL(sub.ProgramID, 0)
						AND ISNULL(det.RateTypeID, 0) = ISNULL(sub.RateTypeID, 0)
						AND dd.DayID = sub.DayID
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		IF @criDebug = 1
			BEGIN
				IF @criOption = 1
					BEGIN
						PRINT 'Contents of day-by-day schedule table:'

						SELECT	*
						FROM	#tmpScheduleDayByDay (NOLOCK)
					END
			END

		/* Get attendance data (if basing calculations on attendance) */
		IF @criUseAttendance = 1
			BEGIN
				INSERT	#tmpAttendanceDetail
					(AttendanceDate,
					ChildID,
					ProviderID,
					ScheduleDetailID,
					ProgramID,
					Hours,
					RateTypeID,
					FullTimeRate,
					PartTimeRate,
					Pay)
				SELECT	DISTINCT
						a.AttendanceDate,
						a.ChildID,
						a.ProviderID,
						adet.ScheduleDetailID,
						adet.ProgramID,
						adet.Hours,
						adet.RateTypeID,
						adet.FullTimeRate,
						adet.PartTimeRate,
						CASE
							WHEN adet.Pay IS NULL
								THEN 0
							ELSE adet.Pay
						END
				FROM	tblAttendanceHistory a (NOLOCK)
						JOIN tblAttendanceHistoryDetail adet (NOLOCK)
							ON a.AttendanceHistoryID = adet.AttendanceHistoryID
						JOIN tblProvider prov (NOLOCK)
							ON a.ProviderID = prov.ProviderID
						JOIN #tmpScheduleCopy s (NOLOCK)
							ON a.ChildID = s.ChildID
								AND a.ProviderID = s.ProviderID
						JOIN #tmpScheduleDetail det (NOLOCK)
							ON s.ScheduleID = det.ScheduleID
								AND adet.ScheduleDetailID = det.ScheduleDetailID
						LEFT JOIN tblChildAbsence abs (NOLOCK)
							ON a.ChildID = abs.ChildID
								AND a.AttendanceDate BETWEEN abs.AbsenceStartDate AND abs.AbsenceStopDate
						LEFT JOIN tlkpAbsenceType lkp (NOLOCK)
							ON abs.AbsenceTypeID = lkp.AbsenceTypeID
				WHERE	a.AttendanceDate BETWEEN @procStartDate AND @procStopDate
						--Exclude days with absences if prohibited based on options
						--Attendance entry is prohibited for these days and is usually cleared during the
						--attendance entry process, but absences entered later may not clear attendance
						AND (lkp.Excused = 1
								AND @optPayExcusedAbsences = 1
								AND prov.AbsenceCharge = 1
							OR lkp.Excused = 0
								AND @optPayUnexcusedAbsences = 1
								AND prov.AbsenceCharge = 1
							OR lkp.Excused IS NULL)

				--Add dummy records for any days during the time period that may not have attendance records
				INSERT #tmpAttendanceDetail
					(AttendanceDate,
					ChildID,
					ProviderID,
					ScheduleDetailID,
					ProgramID,
					Hours,
					RateTypeID,
					FullTimeRate,
					PartTimeRate,
					Pay)
				SELECT	DISTINCT
						sub.CalendarDate,
						sub.ChildID,
						sub.ProviderID,
						NULL,
						NULL,
						NULL,
						NULL,
						NULL,
						NULL,
						0
				FROM	(SELECT	cal.CalendarDate,
								det.ChildID,
								det.ProviderID
						FROM	#tmpCalendar cal (NOLOCK),
								(SELECT	DISTINCT
										ChildID,
										ProviderID
								FROM	#tmpAttendanceDetail (NOLOCK)
								WHERE	AttendanceDate BETWEEN @procStartDate AND @procStopDate) det) sub
						LEFT JOIN #tmpAttendanceDetail tmp (NOLOCK)
							ON sub.CalendarDate = tmp.AttendanceDate
								AND sub.ChildID = tmp.ChildID
								AND sub.ProviderID = tmp.ProviderID
				WHERE	sub.CalendarDate BETWEEN @procStartDate AND @procStopDate
						AND tmp.AttendanceDate IS NULL
			END

		--Set number of hours per day
		--Not currently needed; determination of full-time/part-time
		--will be based on scheduled rather than actual attendance
		--UPDATE	adet
		--SET		HoursPerDay = sub.TotalHours
		--FROM	#tmpAttendanceDetail adet
		--		JOIN #tmpScheduleDetail det (NOLOCK)
		--			ON adet.ScheduleDetailID = det.ScheduleDetailID
		--		JOIN	(SELECT		detsub.ScheduleID,
		--							detsub.PaymentTypeCode,
		--							detsub.ProgramID,
		--							detsub.RateTypeID,
		--							adetsub.AttendanceDate,
		--							SUM(adetsub.Hours) AS TotalHours
		--				FROM		#tmpScheduleDetail detsub (NOLOCK)
		--							JOIN #tmpScheduleDetailDay ddsub (NOLOCK)
		--								ON detsub.ScheduleDetailID = ddsub.ScheduleDetailID
		--							JOIN #tmpAttendanceDetail adetsub (NOLOCK)
		--								ON detsub.ScheduleDetailID = adetsub.ScheduleDetailID
		--									AND ddsub.DayID = DATEPART(WEEKDAY, adetsub.AttendanceDate)
		--				WHERE		detsub.Hours IS NOT NULL
		--				GROUP BY	detsub.ScheduleID,
		--							detsub.PaymentTypeCode,
		--							detsub.ProgramID,
		--							detsub.RateTypeID,
		--							adetsub.AttendanceDate) sub
		--			ON det.ScheduleID = sub.ScheduleID
		--				AND det.PaymentTypeCode = sub.PaymentTypeCode
		--				AND ISNULL(det.ProgramID, 0) = ISNULL(sub.ProgramID, 0)
		--				AND ISNULL(det.RateTypeID, 0) = ISNULL(sub.RateTypeID, 0)
		--				AND adet.AttendanceDate = sub.AttendanceDate

		/* Pull in child school data */
		SELECT	@procDebugMessage = 'Insert school data'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT
			
		INSERT #tmpChildSchool
			(ChildID,
			SchoolID,
			SchoolTrackID,
			CalendarDate)
		SELECT	DISTINCT
				cs.ChildID,
				cs.SchoolID,
				cs.SchoolTrackID,
				dbd.CalendarDate
		FROM	tlnkChildSchool cs (NOLOCK)
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON cs.ChildID = sched.ChildID
				JOIN #tmpScheduleDayByDay dbd (NOLOCK)
					ON sched.ScheduleID = dbd.ScheduleID
		WHERE	(cs.StartDate <= dbd.CalendarDate
					OR cs.StartDate IS NULL)
				AND (cs.StopDate >= dbd.CalendarDate
					OR cs.StopDate IS NULL)

		/* Determine regular or vacation day */
		SELECT	@procDebugMessage = 'Vacation day flagging'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT
			
		--Flag district vacation days
		UPDATE	dbd
		SET		PaymentTypeCode = @constPaymentTypeCode_Vacation
		FROM	#tmpScheduleDayByDay dbd (NOLOCK)
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN #tmpChildSchool cs
					ON sched.ChildID = cs.ChildID
						AND dbd.CalendarDate = cs.CalendarDate
				JOIN tblSchool sch (NOLOCK)
					ON cs.SchoolID = sch.SchoolID
				JOIN tlkpSchoolDistrictVacation vac (NOLOCK)
					ON sch.SchoolDistrictID = vac.SchoolDistrictID
		WHERE	(vac.StartDate IS NULL
					OR vac.StartDate <= cs.CalendarDate)
				AND (vac.StopDate IS NULL
					OR vac.StopDate >= cs.CalendarDate)
		OPTION	(KEEP PLAN)

		--Determine whether to follow track vacation days or district vacation days
		--If track vacation has priority, reset all days to regular if the child
		--has a school track selected (this will ensure that only the track vacation
		--schedule is used); otherwise use district vacation schedule
		IF @optTrackPriority = 1
			UPDATE	dbd
			SET		PaymentTypeCode = @constPaymentTypeCode_Regular
			FROM	#tmpScheduleDayByDay dbd (NOLOCK)
					JOIN #tmpScheduleCopy sched (NOLOCK)
						ON dbd.ScheduleID = sched.ScheduleID
					JOIN #tmpChildSchool cs 
						ON sched.ChildID = cs.ChildID
							AND dbd.CalendarDate = cs.CalendarDate
			WHERE	cs.SchoolTrackID IS NOT NULL
			OPTION	(KEEP PLAN)

		--Flag track vacation days
		UPDATE	dbd
		SET		PaymentTypeCode = @constPaymentTypeCode_Vacation
		FROM	#tmpScheduleDayByDay dbd (NOLOCK)
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN #tmpChildSchool cs 
					ON sched.ChildID = cs.ChildID
						AND dbd.CalendarDate = cs.CalendarDate
				JOIN tlkpSchoolTrackVacation vac (NOLOCK)
					ON cs.SchoolTrackID = vac.SchoolTrackID
		WHERE	(vac.StartDate IS NULL
					OR vac.StartDate <= dbd.CalendarDate)
				AND (vac.StopDate IS NULL
					OR vac.StopDate >= dbd.CalendarDate)
		OPTION	(KEEP PLAN)

		IF @criOption = 3
			DELETE	sdd
			FROM	#tmpScheduleDayByDay sdd
					JOIN #tmpScheduleDetail sd (NOLOCK)
						ON sdd.ScheduleID = sd.ScheduleID
							AND sdd.PaymentTypeCode = sd.PaymentTypeCode
			WHERE	sd.FixedFee = 1			

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Insert schedule detail day-by-day data */
		SELECT	@procDebugMessage = 'Schedule detail day-by-day data generation'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Determine first and last day that care is scheduled during the calculation period
		--This needs to be done to handle cases where, for instance, the first week of the month is only a Saturday
		--and no care is scheduled for Saturdays
		--In those cases the calculation needs to be able to determine that there was care each week
		UPDATE	sdbd
		SET		FirstDayOfScheduledCare = sub.FirstDayOfScheduledCare
		FROM	#tmpScheduleDayByDay sdbd
				JOIN	(SELECT		sched.ScheduleID,
									MIN(cal.CalendarDate) AS FirstDayOfScheduledCare
						FROM		tblSchedule sched (NOLOCK)
									JOIN #tmpScheduleCopy s (NOLOCK)
										ON sched.ScheduleID = s.ScheduleID
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
									JOIN tlnkScheduleDetailDay sdd (NOLOCK)
										ON det.ScheduleDetailID = sdd.ScheduleDetailID
									JOIN #tmpCalendar cal (NOLOCK)
										ON sdd.DayID = cal.DayOfWeek
									JOIN tlkpPaymentType pt (NOLOCK)
										ON det.PaymentTypeID = pt.PaymentTypeID
									LEFT JOIN tlnkChildSchool cs (NOLOCK)
										ON sched.ChildID = cs.ChildID
											AND cal.CalendarDate >= ISNULL(cs.StartDate, cal.CalendarDate)
											AND cal.CalendarDate <= ISNULL(cs.StopDate, cal.CalendarDate)
									LEFT JOIN tblSchool sch (NOLOCK)
										ON cs.SchoolID = sch.SchoolID
									LEFT JOIN tlkpSchoolTrack st (NOLOCK)
										ON cs.SchoolTrackID = st.SchoolTrackID
									LEFT JOIN tlkpSchoolDistrict sdtrct (NOLOCK)
										ON sch.SchoolDistrictID = sdtrct.SchoolDistrictID
									LEFT JOIN tlkpSchoolTrackVacation stv (NOLOCK)
										ON st.SchoolTrackID = stv.SchoolTrackID
											AND cal.CalendarDate >= ISNULL(stv.StartDate, @criStartDate)
											AND cal.CalendarDate <= ISNULL(stv.StopDate, @criStopDate)
									LEFT JOIN tlkpSchoolDistrictVacation sdv (NOLOCK)
										ON sdtrct.SchoolDistrictID = sdv.SchoolDistrictID
											AND cal.CalendarDate >= ISNULL(sdv.StartDate, @criStartDate)
											AND cal.CalendarDate <= ISNULL(sdv.StopDate, @criStopDate)
						WHERE		((pt.PaymentTypeCode = '01'  --Regular with neither district nor school track vacation
											AND stv.SchoolTrackVacationID IS  NULL
											AND sdv.SchoolDistrictVacationID IS NULL)
										OR (pt.PaymentTypeCode = '01' --Regular without school track vacation but having a district vacation that
											AND stv.SchoolTrackVacationID IS NULL -- is excluded due to school track having priority
											AND (sdv.SchoolDistrictVacationID IS NOT NULL
												AND @optTrackPriority = 1))
										OR (pt.PaymentTypeCode = '02'--Vacation with school track
											AND @optTrackPriority = 1
											AND stv.SchoolTrackVacationID IS NOT NULL)
										OR	(pt.PaymentTypeCode = '02' --School district vacation with school track priority disabled
											AND @optTrackPriority = 0
											AND (stv.SchoolTrackVacationID IS NOT NULL
												OR sdv.SchoolDistrictVacationID IS NOT NULL)))
									AND cal.CalendarDate BETWEEN @procStartDate AND @procStopDate
						GROUP BY	sched.ScheduleID) sub
					ON sdbd.ScheduleID = sub.ScheduleID

		UPDATE	sdbd
		SET		LastDayOfScheduledCare = sub.LastDayOfScheduledCare
		FROM	#tmpScheduleDayByDay sdbd
				JOIN	(SELECT		sched.ScheduleID,
									MAX(cal.CalendarDate) AS LastDayOfScheduledCare
						FROM		tblSchedule sched (NOLOCK)
									JOIN #tmpScheduleCopy s (NOLOCK)
										ON sched.ScheduleID = s.ScheduleID
									JOIN tblScheduleDetail det (NOLOCK)
										ON sched.ScheduleID = det.ScheduleID
									JOIN tlnkScheduleDetailDay sdd (NOLOCK)
										ON det.ScheduleDetailID = sdd.ScheduleDetailID
									JOIN #tmpCalendar cal (NOLOCK)
										ON sdd.DayID = cal.DayOfWeek
									JOIN tlkpPaymentType pt (NOLOCK)
										ON det.PaymentTypeID = pt.PaymentTypeID
									LEFT JOIN tlnkChildSchool cs (NOLOCK)
										ON sched.ChildID = cs.ChildID
											AND cal.CalendarDate >= ISNULL(cs.StartDate, cal.CalendarDate)
											AND cal.CalendarDate <= ISNULL(cs.StopDate, cal.CalendarDate)
									LEFT JOIN tblSchool sch (NOLOCK)
										ON cs.SchoolID = sch.SchoolID
									LEFT JOIN tlkpSchoolTrack st (NOLOCK)
										ON cs.SchoolTrackID = st.SchoolTrackID
									LEFT JOIN tlkpSchoolDistrict sdtrct (NOLOCK)
										ON sch.SchoolDistrictID = sdtrct.SchoolDistrictID
									LEFT JOIN tlkpSchoolTrackVacation stv (NOLOCK)
										ON st.SchoolTrackID = stv.SchoolTrackID
											AND cal.CalendarDate >= ISNULL(stv.StartDate, @criStartDate)
											AND cal.CalendarDate <= ISNULL(stv.StopDate, @criStopDate)
									LEFT JOIN tlkpSchoolDistrictVacation sdv (NOLOCK)
										ON sdtrct.SchoolDistrictID = sdv.SchoolDistrictID
											AND cal.CalendarDate >= ISNULL(sdv.StartDate, @criStartDate)
											AND cal.CalendarDate <= ISNULL(sdv.StopDate, @criStopDate)
						WHERE		((pt.PaymentTypeCode = '01'  --Regular with neither district nor school track vacation
											AND stv.SchoolTrackVacationID IS  NULL
											AND sdv.SchoolDistrictVacationID IS NULL)
										OR (pt.PaymentTypeCode = '01' --Regular without school track vacation but having a district vacation that
											AND stv.SchoolTrackVacationID IS NULL -- is excluded due to school track having priority
											AND (sdv.SchoolDistrictVacationID IS NOT NULL
												AND @optTrackPriority = 1))
										OR (pt.PaymentTypeCode = '02'--Vacation with school track
											AND @optTrackPriority = 1
											AND stv.SchoolTrackVacationID IS NOT NULL)
										OR	(pt.PaymentTypeCode = '02' --School district vacation with school track priority disabled
											AND @optTrackPriority = 0
											AND (stv.SchoolTrackVacationID IS NOT NULL
												OR sdv.SchoolDistrictVacationID IS NOT NULL)))
									AND cal.CalendarDate BETWEEN @procStartDate AND @procStopDate
						GROUP BY	sched.ScheduleID) sub
					ON sdbd.ScheduleID = sub.ScheduleID

		IF @optProgramSource = 1 --Child level
			INSERT	#tmpDayByDay
				(ScheduleID,
				ScheduleDetailID,
				ExtendedSchedule,
				CalendarDate,
				DayOfWeek,
				WeekStart,
				WeekStop,
				MonthStart,
				MonthStop,
				WeekNumber,
				WeeksInMonth,
				BookendWeek,
				ProgramID,
				Hours,
				HoursPerDay,
				HoursPerWeek,
				Evening,
				Weekend,
				PaymentTypeID,
				AttendanceRateTypeID,
				AttendanceFullTimeRate,
				AttendancePartTimeRate,
				RateBookDetailID,
				FullFeeRateBookDetailID,
				Breakfast,
				Lunch,
				Snack,
				Dinner)
			SELECT	DISTINCT
					sdbd.ScheduleID,
					det.ScheduleDetailID,
					sdbd.ExtendedSchedule,
					sdbd.CalendarDate,
					sdbd.DayOfWeek,
					sdbd.WeekStart,
					sdbd.WeekStop,
					sdbd.MonthStart,
					sdbd.MonthStop,
					CASE
						WHEN DATEPART(WEEK, sdbd.CalendarDate) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1 < 0
							THEN 0
						ELSE DATEPART(WEEK, sdbd.CalendarDate) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1
					END,
					CASE
						WHEN DATEPART(WEEK, sdbd.LastDayOfScheduledCare) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1 < 0
							THEN 0
						ELSE DATEPART(WEEK, sdbd.LastDayOfScheduledCare) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1
					END,
					CASE
						WHEN DATEPART(WEEKDAY, sdbd.WeekStart) <> 1
								OR DATEPART(WEEKDAY, sdbd.WeekStop) <> 7
							THEN 1
						ELSE 0
					END,
					CASE
						WHEN @criUseAttendance = 0 OR adet.ProgramID IS NULL
							THEN cp.ProgramID
						ELSE adet.ProgramID
					END,
					CASE
						WHEN @criUseAttendance = 0
							THEN det.Hours
						ELSE adet.Hours
					END,
					sdd.HoursPerDay,
					det.HoursPerWeek,
					det.Evening,
					det.Weekend,
					CASE sdbd.PaymentTypeCode
						WHEN @constPaymentTypeCode_Regular
							THEN @constPaymentTypeID_Regular
						WHEN @constPaymentTypeCode_Vacation
							THEN @constPaymentTypeID_Vacation
					END,
					adet.RateTypeID,
					adet.FullTimeRate,
					adet.PartTimeRate,
					det.RateBookDetailID,
					det.FullFeeRateBookDetailID,
					det.Breakfast,
					det.Lunch,
					det.Snack,
					det.Dinner
			FROM	#tmpScheduleDayByDay sdbd (NOLOCK)
					JOIN #tmpScheduleDetail det (NOLOCK)
						ON sdbd.ScheduleID = det.ScheduleID
							AND sdbd.PaymentTypeCode = det.PaymentTypeCode
					JOIN #tmpScheduleCopy s (NOLOCK)
						ON sdbd.ScheduleID = s.ScheduleID
					JOIN tlnkChildProgram cp (NOLOCK)
						ON s.ChildID = cp.ChildID
					LEFT JOIN tlkpRateType rt (NOLOCK)
						ON det.RateTypeID = rt.RateTypeID
					LEFT JOIN #tmpScheduleDetailDay sdd
						ON det.ScheduleDetailID = sdd.ScheduleDetailID
							AND sdbd.DayOfWeek = sdd.DayID
					LEFT JOIN #tmpAttendanceDetail adet (NOLOCK)
						ON (det.ScheduleDetailID = adet.ScheduleDetailID
								OR adet.ScheduleDetailID IS NULL
									AND s.ChildID = adet.ChildID
									AND s.ProviderID = adet.ProviderID)
							AND sdbd.CalendarDate = adet.AttendanceDate
			WHERE	(cp.StartDate <= sdbd.CalendarDate
						OR cp.StartDate IS NULL)
					AND (cp.StopDate >= sdbd.CalendarDate
						OR cp.StopDate IS NULL)
					AND (@criUseAttendance = 0
						OR (det.ScheduleDetailID = adet.ScheduleDetailID
								OR adet.ScheduleDetailID IS NULL)
							AND sdbd.CalendarDate = adet.AttendanceDate)
			OPTION	(KEEP PLAN)

		IF @optProgramSource = 2 --Schedule detail level
			INSERT	#tmpDayByDay
				(ScheduleID,
				ScheduleDetailID,
				ExtendedSchedule,
				CalendarDate,
				DayOfWeek,
				WeekStart,
				WeekStop,
				MonthStart,
				MonthStop,
				WeekNumber,
				WeeksInMonth,
				BookendWeek,
				ProgramID,
				Hours,
				HoursPerDay,
				HoursPerWeek,
				Evening,
				Weekend,
				PaymentTypeID,
				AttendanceRateTypeID,
				AttendanceFullTimeRate,
				AttendancePartTimeRate,
				RateBookDetailID,
				FullFeeRateBookDetailID,
				Breakfast,
				Lunch,
				Snack,
				Dinner)
			SELECT	DISTINCT
					sdbd.ScheduleID,
					det.ScheduleDetailID,
					sdbd.ExtendedSchedule,
					sdbd.CalendarDate,
					sdbd.DayOfWeek,
					sdbd.WeekStart,
					sdbd.WeekStop,
					sdbd.MonthStart,
					sdbd.MonthStop,
					CASE
						WHEN DATEPART(WEEK, sdbd.CalendarDate) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1 < 0
							THEN 0
						ELSE DATEPART(WEEK, sdbd.CalendarDate) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1
					END,
					CASE
						WHEN DATEPART(WEEK, sdbd.LastDayOfScheduledCare) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1 < 0
							THEN 0
						ELSE DATEPART(WEEK, sdbd.LastDayOfScheduledCare) - DATEPART(WEEK, sdbd.FirstDayOfScheduledCare) + 1
					END,
					CASE
						WHEN DATEPART(WEEKDAY, sdbd.WeekStart) <> 1
								OR DATEPART(WEEKDAY, sdbd.WeekStop) <> 7
							THEN 1
						ELSE 0
					END,
					CASE
						WHEN @criUseAttendance = 0 OR adet.ProgramID IS NULL
							THEN det.ProgramID
						ELSE adet.ProgramID
					END,
					CASE
						WHEN @criUseAttendance = 0
							THEN det.Hours
						ELSE adet.Hours
					END,
					sdd.HoursPerDay,
					det.HoursPerWeek,
					det.Evening,
					det.Weekend,
					CASE sdbd.PaymentTypeCode
						WHEN @constPaymentTypeCode_Regular
							THEN @constPaymentTypeID_Regular
						WHEN @constPaymentTypeCode_Vacation
							THEN @constPaymentTypeID_Vacation
					END,
					adet.RateTypeID,
					adet.FullTimeRate,
					adet.PartTimeRate,
					det.RateBookDetailID,
					det.FullFeeRateBookDetailID,
					det.Breakfast,
					det.Lunch,
					det.Snack,
					det.Dinner
			FROM	#tmpScheduleDayByDay sdbd (NOLOCK)
					JOIN #tmpScheduleDetail det (NOLOCK)
						ON sdbd.ScheduleID = det.ScheduleID
							AND sdbd.PaymentTypeCode = det.PaymentTypeCode
					JOIN #tmpScheduleCopy sched (NOLOCK)
						ON sdbd.ScheduleID = sched.ScheduleID
					LEFT JOIN tlkpRateType rt (NOLOCK)
						ON det.RateTypeID = rt.RateTypeID
					LEFT JOIN #tmpScheduleDetailDay sdd
						ON det.ScheduleDetailID = sdd.ScheduleDetailID
							AND sdbd.DayOfWeek = sdd.DayID
					LEFT JOIN #tmpAttendanceDetail adet (NOLOCK)
						ON (det.ScheduleDetailID = adet.ScheduleDetailID
								OR adet.ScheduleDetailID IS NULL
									AND sched.ChildID = adet.ChildID
									AND sched.ProviderID = adet.ProviderID)
							AND sdbd.CalendarDate = adet.AttendanceDate
			WHERE	@criUseAttendance = 0
					OR (det.ScheduleDetailID = adet.ScheduleDetailID
							OR adet.ScheduleDetailID IS NULL)
						AND sdbd.CalendarDate = adet.AttendanceDate
			OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Set days per week/month */
		--This is based on scheduled days that fall within the date range of the week/month
		--This should only be done if calculation is based on attendance
		--If not based on attendance days per week will be assumed to be 5 and days per month will be based on the calendar days in that month
		IF @optProrationMethod = 2
			BEGIN
				SELECT	@procDebugMessage = 'Set days per week/month'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Set "true" start and stop days for the week
				UPDATE	dbd
				SET		TrueWeekStart = sub.TrueWeekStart
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		tmp.CalendarDate,
											MAX(cal.WeekStart) AS TrueWeekStart
								FROM		#tmpDayByDay tmp (NOLOCK),
											#tmpCalendar cal (NOLOCK)
								WHERE		cal.WeekStart < tmp.CalendarDate
												AND DATEPART(WEEKDAY, cal.WeekStart) = 1
											OR cal.WeekStart = tmp.CalendarDate
												AND DATEPART(WEEKDAY, tmp.CalendarDate) = 1
								GROUP BY	tmp.CalendarDate) sub
							ON dbd.CalendarDate = sub.CalendarDate

				UPDATE	dbd
				SET		TrueWeekStop = sub.TrueWeekStop
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		tmp.CalendarDate,
											MIN(cal.WeekStop) AS TrueWeekStop
								FROM		#tmpDayByDay tmp (NOLOCK),
											#tmpCalendar cal (NOLOCK)
								WHERE		cal.WeekStop > tmp.CalendarDate
												AND DATEPART(WEEKDAY, cal.WeekStop) = 7
											OR cal.WeekStop = tmp.CalendarDate
												AND DATEPART(WEEKDAY, tmp.WeekStop) = 7
								GROUP BY	tmp.CalendarDate) sub
							ON dbd.CalendarDate = sub.CalendarDate

				--Set days per week
				UPDATE	dbd
				SET		DaysPerWeek = sub.TotalDays
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		daybyday.ScheduleID,
											daybyday.AttendanceRateTypeID,
											daybyday.ProgramID,
											tmp.TrueWeekStart,
											tmp.TrueWeekStop,
											COUNT(DISTINCT sdd.DayID) AS TotalDays
								FROM		tlnkScheduleDetailDay sdd (NOLOCK)
											JOIN #tmpDayByDay daybyday (NOLOCK)
												ON sdd.ScheduleDetailID = daybyday.ScheduleDetailID
											JOIN	(SELECT	DISTINCT
															ScheduleDetailID,
															TrueWeekStart,
															TrueWeekStop
													FROM	#tmpDayByDay (NOLOCK)) tmp
												ON sdd.ScheduleDetailID = tmp.ScheduleDetailID
											JOIN #tmpCalendar cal (NOLOCK)
												ON sdd.DayID = cal.DayOfWeek
								WHERE		cal.CalendarDate BETWEEN tmp.TrueWeekStart AND tmp.TrueWeekStop
								GROUP BY	daybyday.ScheduleID,
											daybyday.AttendanceRateTypeID,
											daybyday.ProgramID,
											tmp.TrueWeekStart,
											tmp.TrueWeekStop) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
								AND dbd.ProgramID = sub.ProgramID
								AND dbd.TrueWeekStart = sub.TrueWeekStart
								AND dbd.TrueWeekStop = sub.TrueWeekStop

				--Set days per week for family fees
				UPDATE	dbd
				SET		DaysPerWeekFamilyFee = sub.TotalDays
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleCopy s (NOLOCK)
							ON dbd.ScheduleID = s.ScheduleID
						JOIN	(SELECT		sched.ChildID,
											daybyday.ProgramID,
											daybyday.TrueWeekStart,
											daybyday.TrueWeekStop,
											COUNT(DISTINCT daybyday.DayOfWeek) AS TotalDays
								FROM		#tmpDayByDay daybyday (NOLOCK)
											JOIN #tmpScheduleCopy sched (NOLOCK)
												ON daybyday.ScheduleID = sched.ScheduleID
											JOIN #tmpCalendar cal (NOLOCK)
												ON daybyday.DayOfWeek = cal.DayOfWeek
													AND daybyday.TrueWeekStart = cal.WeekStart
													--AND daybyday.CalendarDate = cal.CalendarDate  /*added by SDR */
								WHERE		cal.CalendarDate BETWEEN daybyday.TrueWeekStart AND daybyday.TrueWeekStop
								GROUP BY	sched.ChildID,
											daybyday.ProgramID,
											daybyday.TrueWeekStart,
											daybyday.TrueWeekStop) sub
							ON s.ChildID = sub.ChildID
								AND dbd.ProgramID = sub.ProgramID
								AND dbd.TrueWeekStart = sub.TrueWeekStart
								AND dbd.TrueWeekStop = sub.TrueWeekStop

				INSERT	#tmpDaysPerMonth
					(ScheduleID,
					AttendanceRateTypeID,
					ProgramID,
					MonthStart,
					MonthStop,
					DaysPerMonth)
				SELECT		tmp.ScheduleID,
							tmp.AttendanceRateTypeID,
							tmp.ProgramID,
							tmp.MonthStart,
							tmp.MonthStop,
							COUNT(DISTINCT cal.CalendarDate) AS TotalDays
				FROM		tlnkScheduleDetailDay sdd (NOLOCK)
							JOIN #tmpDayByDay tmp (NOLOCK)
								ON sdd.ScheduleDetailID = tmp.ScheduleDetailID
							JOIN #tmpCalendar cal (NOLOCK)
								ON sdd.DayID = cal.DayOfWeek
				WHERE		cal.CalendarDate BETWEEN tmp.MonthStart AND tmp.MonthStop
				GROUP BY	tmp.ScheduleID,
							tmp.AttendanceRateTypeID,
							tmp.ProgramID,
							tmp.MonthStart,
							tmp.MonthStop

				UPDATE	dbd
				SET		DaysPerMonth = dpm.DaysPerMonth
				FROM	#tmpDayByDay dbd
						JOIN #tmpDaysPerMonth dpm (NOLOCK)
							ON dbd.ScheduleID = dpm.ScheduleID
								AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(dpm.AttendanceRateTypeID, 0)
								AND dbd.ProgramID = dpm.ProgramID
								AND dbd.MonthStart = dpm.MonthStart
								AND dbd.MonthStop = dpm.MonthStop

				/* Commented out as part of task 4788 to prevent double-counting unexcused absences
				See inserts into #tmpAttendanceDetail above which makes sure that there will be attendance entries even for days with unexcused absences

				--Add unexcused absences back in as these days would have been removed from attendance entry already
				--This is needed because the count of days per month is tied back to individual attendance days, unlike days per week
				IF @criUseAttendance = 1
					UPDATE	dbd
					SET		DaysPerMonth = DaysPerMonth + sub.UnexcusedAbsences
					FROM	#tmpDayByDay dbd
							JOIN	(SELECT		tmp.ScheduleID,
												tmp.AttendanceRateTypeID,
												tmp.ProgramID,
												tmp.MonthStart,
												tmp.MonthStop,
												COUNT(DISTINCT cal.CalendarDate) AS UnexcusedAbsences
									FROM		(SELECT	DISTINCT
														ScheduleID,
														AttendanceRateTypeID,
														ProgramID,
														MonthStart,
														MonthStop
												FROM	#tmpDayByDay (NOLOCK)) tmp
												JOIN #tmpScheduleCopy s (NOLOCK)
													ON tmp.ScheduleID = s.ScheduleID
												JOIN tblChildAbsence abs (NOLOCK)
													ON s.ChildID = abs.ChildID
												JOIN tlkpAbsenceType lkp (NOLOCK)
													ON abs.AbsenceTypeID = lkp.AbsenceTypeID
												JOIN #tmpCalendar cal (NOLOCK)
													ON abs.AbsenceStartDate <= cal.CalendarDate
														AND abs.AbsenceStopDate >= cal.CalendarDate
									WHERE		cal.CalendarDate BETWEEN @procStartDate AND @procStopDate
												AND (s.StartDate <= cal.CalendarDate
													OR s.StartDate IS NULL)
												AND (s.StopDate >= cal.CalendarDate
													OR s.StopDate IS NULL)
												AND lkp.Excused = 0
									GROUP BY	tmp.ScheduleID,
												tmp.AttendanceRateTypeID,
												tmp.ProgramID,
												tmp.MonthStart,
												tmp.MonthStop) sub
								ON dbd.ScheduleID = sub.ScheduleID
									AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
									AND dbd.ProgramID = sub.ProgramID
									AND dbd.MonthStart = sub.MonthStart
									AND dbd.MonthStop = sub.MonthStop
				*/

				--Set days per month for family fees
				UPDATE	dbd
				SET		DaysPerMonthFamilyFee = sub.TotalDays
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleCopy s (NOLOCK)
							ON dbd.ScheduleID = s.ScheduleID
						JOIN	(SELECT		sched.ChildID,
											tmp.ProgramID,
											tmp.MonthStart,
											tmp.MonthStop,
											COUNT(DISTINCT cal.CalendarDate) AS TotalDays
								FROM		tlnkScheduleDetailDay sdd (NOLOCK)
											JOIN #tmpDayByDay tmp (NOLOCK)
												ON sdd.ScheduleDetailID = tmp.ScheduleDetailID
											JOIN #tmpScheduleCopy sched (NOLOCK)
												ON tmp.ScheduleID = sched.ScheduleID
											JOIN #tmpCalendar cal (NOLOCK)
												ON sdd.DayID = cal.DayOfWeek
								WHERE		cal.CalendarDate BETWEEN tmp.MonthStart AND tmp.MonthStop
								GROUP BY	sched.ChildID,
											tmp.ProgramID,
											tmp.MonthStart,
											tmp.MonthStop) sub
							ON s.ChildID = sub.ChildID
								AND dbd.ProgramID = sub.ProgramID
								AND dbd.MonthStart = sub.MonthStart
								AND dbd.MonthStop = sub.MonthStop

				/* Commented out as part of task 4788 to prevent double-counting unexcused absences
				See inserts into #tmpAttendanceDetail above which makes sure that there will be attendance entries even for days with unexcused absences

				--Add unexcused absences back in as these days would have been removed from attendance entry already
				--This is needed because the count of days per month is tied back to individual attendance days, unlike days per week
				IF @criUseAttendance = 1
					UPDATE	dbd
					SET		DaysPerMonthFamilyFee = DaysPerMonthFamilyFee + sub.UnexcusedAbsences
					FROM	#tmpDayByDay dbd
							JOIN #tmpScheduleCopy sched (NOLOCK)
								ON dbd.ScheduleID = sched.ScheduleID
							JOIN	(SELECT		s.ChildID,
												tmp.ProgramID,
												tmp.MonthStart,
												tmp.MonthStop,
												COUNT(DISTINCT cal.CalendarDate) AS UnexcusedAbsences
									FROM		(SELECT	DISTINCT
														ScheduleID,
														ProgramID,
														MonthStart,
														MonthStop
												FROM	#tmpDayByDay (NOLOCK)) tmp
												JOIN #tmpScheduleCopy s (NOLOCK)
													ON tmp.ScheduleID = s.ScheduleID
												JOIN tblChildAbsence abs (NOLOCK)
													ON s.ChildID = abs.ChildID
												JOIN tlkpAbsenceType lkp (NOLOCK)
													ON abs.AbsenceTypeID = lkp.AbsenceTypeID
												JOIN #tmpCalendar cal (NOLOCK)
													ON abs.AbsenceStartDate <= cal.CalendarDate
														AND abs.AbsenceStopDate >= cal.CalendarDate
									WHERE		cal.CalendarDate BETWEEN @procStartDate AND @procStopDate
												AND (s.StartDate <= cal.CalendarDate
													OR s.StartDate IS NULL)
												AND (s.StopDate >= cal.CalendarDate
													OR s.StopDate IS NULL)
												AND lkp.Excused = 0
									GROUP BY	s.ChildID,
												tmp.ProgramID,
												tmp.MonthStart,
												tmp.MonthStop) sub
								ON sched.ChildID = sub.ChildID
									AND dbd.ProgramID = sub.ProgramID
									AND dbd.MonthStart = sub.MonthStart
									AND dbd.MonthStop = sub.MonthStop
				*/

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Set actual hours per day/week and actual days per week, and determine if care is provided each week of the month */
		IF @criUseAttendance = 1 AND @optAutoSetRateType = 1
			BEGIN
				--Hours per day
				UPDATE	dbd
				SET		ActualHoursPerDay = sub.TotalHours
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		ScheduleID,
											ProgramID,
											CalendarDate,
											SUM(Hours) AS TotalHours
								FROM		#tmpDayByDay
								GROUP BY	ScheduleID,
											ProgramID,
											CalendarDate) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND dbd.ProgramID = sub.ProgramID
								AND dbd.CalendarDate = sub.CalendarDate

				--Hours per week
				UPDATE	dbd
				SET		ActualHoursPerWeek = sub.TotalHours
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		ScheduleID,
											ProgramID,
											AttendanceRateTypeID,
											WeekStart,
											SUM(Hours) AS TotalHours
								FROM		#tmpDayByDay
								GROUP BY	ScheduleID,
											ProgramID,
											AttendanceRateTypeID,
											WeekStart) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND dbd.ProgramID = sub.ProgramID
								AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
								AND dbd.WeekStart = sub.WeekStart

				--Days per week
				UPDATE	dbd
				SET		ActualDaysPerWeek = sub.DaysPerWeek
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		tmp.ScheduleID,
											tmp.ProgramID,
											tmp.WeekStart,
											--tmp.AttendanceRateTypeID,
											COUNT(DISTINCT tmp.CalendarDate) AS DaysPerWeek
								FROM		#tmpDayByDay tmp (NOLOCK)
											JOIN #tmpScheduleCopy s (NOLOCK)
												ON tmp.ScheduleID = s.ScheduleID
											LEFT JOIN tblChildAbsence ab (NOLOCK)
												ON s.ChildID = ab.ChildID
													AND tmp.CalendarDate BETWEEN ab.AbsenceStartDate AND ab.AbsenceStopDate
								WHERE		tmp.Hours IS NOT NULL
												AND tmp.Hours > 0
											OR ab.ChildAbsenceID IS NOT NULL
								GROUP BY	tmp.ScheduleID,
											tmp.ProgramID,
											--tmp.AttendanceRateTypeID,
											tmp.WeekStart) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND dbd.ProgramID = sub.ProgramID
								--AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
								AND dbd.WeekStart = sub.WeekStart

				--Is care provided each week of the month?
				SELECT	@procCurrentWeek = 1

				SELECT	@procMaxWeek = MAX(WeeksInMonth)
				FROM	#tmpDayByDay (NOLOCK)

				WHILE @procCurrentWeek <= @procMaxWeek
					BEGIN
						UPDATE	dbd
						SET		CareEachWeek = 0
						FROM	#tmpDayByDay dbd
								LEFT JOIN	(SELECT	DISTINCT
													ScheduleID,
													ProgramID,
													AttendanceRateTypeID,
													WeekStart,
													WeekNumber
											FROM	#tmpDayByDay
											WHERE	ActualHoursPerWeek IS NOT NULL
													AND ActualHoursPerWeek > 0) sub
									ON dbd.ScheduleID = sub.ScheduleID
										AND dbd.ProgramID = sub.ProgramID
										AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
										AND dbd.WeekStart = sub.WeekStart
										AND dbd.WeekNumber = sub.WeekNumber
						WHERE	dbd.WeekNumber = @procCurrentWeek
								AND sub.ScheduleID IS NULL

						--If the current week doesn't exist in the day by day table, obviously there isn't care each week
						UPDATE	dbd
						SET		CareEachWeek = 0
						FROM	#tmpDayByDay dbd
								LEFT JOIN	(SELECT	DISTINCT
													ScheduleID,
													ProgramID,
													AttendanceRateTypeID
											FROM	#tmpDayByDay
											WHERE	WeekNumber = @procCurrentWeek) sub
									ON dbd.ScheduleID = sub.ScheduleID
										AND dbd.ProgramID = sub.ProgramID
										AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
						WHERE	sub.ScheduleID IS NULL

						SELECT	@procCurrentWeek = @procCurrentWeek + 1
					END

				UPDATE	dbd
				SET		CareEachWeek = sub.CareEachWeek
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		ScheduleID,
											ProgramID,
											AttendanceRateTypeID,
											MonthStart,
											MIN(CONVERT(TINYINT, CareEachWeek)) AS CareEachWeek
								FROM		#tmpDayByDay (NOLOCK)
								GROUP BY	ScheduleID,
											ProgramID,
											AttendanceRateTypeID,
											MonthStart) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND dbd.ProgramID = sub.ProgramID
								AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
								AND dbd.MonthStart = sub.MonthStart

				--Average hours per week, for use in later comparisons
				--This only needs to be done if there is care each week
				UPDATE	dbd
				SET		AverageHoursPerWeek = sub.AverageHours
				FROM	#tmpDayByDay dbd
						JOIN	(SELECT		tmp.ScheduleID,
											tmp.ProgramID,
											tmp.AttendanceRateTypeID,
											tmp.MonthStart,
											AVG(tmp.ActualHoursPerWeek * tmp.DaysPerWeek / tmp.ActualDaysPerWeek) AS AverageHours
								FROM		(SELECT	DISTINCT
													ScheduleID,
													ProgramID,
													AttendanceRateTypeID,
													WeekStart,
													MonthStart,
													ISNULL(ActualHoursPerWeek, 0) AS ActualHoursPerWeek,
													CASE
														WHEN BookendWeek = 0
															THEN CONVERT(NUMERIC(3, 2), DaysPerWeek)
														WHEN BookendWeek = 1
															THEN CONVERT(NUMERIC(3, 2), ActualDaysPerWeek)
													END AS ActualDaysPerWeek,
													CONVERT(NUMERIC(3, 2), DaysPerWeek) AS DaysPerWeek
											FROM	#tmpDayByDay
											WHERE	CareEachWeek = 1) tmp
								GROUP BY	tmp.ScheduleID,
											tmp.ProgramID,
											tmp.AttendanceRateTypeID,
											tmp.MonthStart) sub
							ON dbd.ScheduleID = sub.ScheduleID
								AND dbd.ProgramID = sub.ProgramID
								AND ISNULL(dbd.AttendanceRateTypeID, 0) = ISNULL(sub.AttendanceRateTypeID, 0)
								AND dbd.MonthStart = sub.MonthStart
				WHERE	dbd.CareEachWeek = 1
			END

		/* If provider does not charge for absences, delete
		days child is absent (except for projections) */
		IF @criOption <> 2
			BEGIN
				SELECT	@procDebugMessage = 'Non-charging provider absence deletion'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				DELETE	dbd
				FROM	#tmpDayByDay dbd (NOLOCK)
						JOIN #tmpScheduleCopy sched (NOLOCK)
							ON dbd.ScheduleID = sched.ScheduleID
						JOIN tblProvider prv (NOLOCK)
							ON sched.ProviderID = prv.ProviderID
						JOIN tblChildAbsence abs (NOLOCK)
							ON sched.ChildID = abs.ChildID
								AND dbd.CalendarDate BETWEEN abs.AbsenceStartDate AND abs.AbsenceStopDate
						JOIN tblChild c (NOLOCK)
							ON abs.ChildID = c.ChildID
						JOIN tblFamily f (NOLOCK)
							ON c.FamilyID = f.FamilyID
						JOIN tlkpAbsenceType t (NOLOCK)
							ON abs.AbsenceTypeID = t.AbsenceTypeID
						LEFT JOIN tblProgram prog (NOLOCK)
							ON dbd.ProgramID = prog.ProgramID
				WHERE	(prv.AbsenceCharge = 0
							OR @optPayExcusedAbsences = 0
								AND t.Excused = 1
							OR @optPayUnexcusedAbsences = 0
								AND t.Excused = 0)
						--For full-fee/private families, check the option to charge for all absences
						AND (@criOption <> 3
							OR prog.FamilyFeeSchedule <> 1
							OR @optFullFeeChargeHolidayAbsenceNonOperation <> 1)
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Remove unpaid provider days of non-operation */
		SELECT	@procDebugMessage = 'Deletion of unpaid provider days of non-operation'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		DELETE	dbd
		FROM	#tmpDayByDay dbd (NOLOCK)
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN tblProvider prv (NOLOCK)
					ON sched.ProviderID = prv.ProviderID
				JOIN tlnkProviderNonOperationalDays nod (NOLOCK)
					ON prv.ProviderID = nod.ProviderID
						AND dbd.CalendarDate = nod.NonOperationalDate
				JOIN tblChild c (NOLOCK)
					ON sched.ChildID = c.ChildID
				JOIN tblFamily f (NOLOCK)
					ON c.FamilyID = f.FamilyID
				LEFT JOIN tblProgram prog (NOLOCK)
					ON dbd.ProgramID = prog.ProgramID
		WHERE	nod.NonOperationalPay = 0
				AND (sched.ClassroomID = nod.ClassroomID
					--If no classroom was entered for a day of non-operation, ClassroomID should be null, but may as well account for the possibility of it being set to 0
					OR nod.ClassroomID IS NULL
					OR nod.ClassroomID = 0)
				--For full-fee/private families, check the option to charge for all days of non-operation
				AND (@criOption <> 3
					OR prog.FamilyFeeSchedule <> 1
					OR @optFullFeeChargeHolidayAbsenceNonOperation <> 1)
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Remove days with programs for children over the max age limit.  This means children who are one year or
		more older than the max age limit for the program.  This excludes children with special needs */
		SELECT	@procDebugMessage = 'Removal of children over program max age'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Insert projection error
		IF @criOption = 2
			INSERT	#tmpError
				(FamilyID,
				ChildID,
				ProgramID,
				ScheduleID,
				ProviderID,
				ErrorDate,
				ErrorCode,
				ErrorDesc)
			SELECT	DISTINCT
					c.FamilyID,
					c.ChildID,
					dbd.ProgramID,
					sched.ScheduleID,
					sched.ProviderID,
					DATEADD(DAY, -1, DATEADD(YEAR, prg.MaxAgeLimit + 1, c.BirthDate)),
					'MA',
					'Program Max Age'
			FROM	#tmpDayByDay dbd
					JOIN #tmpScheduleCopy sched
						ON dbd.ScheduleID = sched.ScheduleID
					JOIN tblProgram prg (NOLOCK)
						ON dbd.ProgramID = prg.ProgramID
					JOIN tblChild c (NOLOCK)
						ON sched.ChildID = c.ChildID
			WHERE	dbd.CalendarDate >= DATEADD(YEAR, prg.MaxAgeLimit + 1, c.BirthDate)
					AND DATEADD(DAY, -1, DATEADD(YEAR, prg.MaxAgeLimit + 1, c.BirthDate)) BETWEEN @procStartDate AND @procStopDate
					AND c.ChildID NOT IN	(SELECT	csn.ChildID
											FROM	tlnkChildSpecialNeed csn (NOLOCK)
													JOIN tlkpSpecialNeed sn (NOLOCK)
														ON csn.SpecialNeedID = sn.SpecialNeedID
											WHERE	(csn.StartDate <= dbd.CalendarDate
														OR csn.StartDate IS NULL)
													AND (csn.StopDate >= dbd.CalendarDate
														OR csn.StopDate IS NULL)
													AND sn.LimitByMaxAge = 0)
			OPTION	(KEEP PLAN)

		DELETE	dbd
		FROM	#tmpDayByDay dbd
				JOIN #tmpScheduleCopy sched
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN tblProgram prg (NOLOCK)
					ON dbd.ProgramID = prg.ProgramID
				JOIN tblChild c (NOLOCK)
					ON sched.ChildID = c.ChildID
		WHERE	dbd.CalendarDate >= DATEADD(YEAR, prg.MaxAgeLimit + 1, c.BirthDate)
				AND c.ChildID NOT IN	(SELECT	csn.ChildID
										FROM	tlnkChildSpecialNeed csn (NOLOCK)
												JOIN tlkpSpecialNeed sn (NOLOCK)
													ON csn.SpecialNeedID = sn.SpecialNeedID
										WHERE	(csn.StartDate <= dbd.CalendarDate
													OR csn.StartDate IS NULL)
												AND (csn.StopDate >= dbd.CalendarDate
													OR csn.StopDate IS NULL)
												AND sn.LimitByMaxAge = 0)
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Set rate type */
		SELECT	@procDebugMessage = 'Rate type update'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		UPDATE	dbd
		SET		RateTypeID = det.RateTypeID
		FROM	#tmpDayByDay dbd
				JOIN #tmpScheduleDetail det
					ON dbd.ScheduleDetailID = det.ScheduleDetailID
		OPTION	(KEEP PLAN)

		--Set rate type based on attendance if applicable
		IF @criUseAttendance = 1
			UPDATE	#tmpDayByDay
			SET		RateTypeID = AttendanceRateTypeID
			WHERE	AttendanceRateTypeID IS NOT NULL

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Mark days not to be paid */
		SELECT	@procDebugMessage = 'Mark days not to be paid'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		UPDATE	dbd
		SET		PayChargeForDay = 0
		FROM	#tmpDayByDay dbd
				JOIN tlkpRateType rt (NOLOCK)
					ON dbd.RateTypeID = rt.RateTypeID
		WHERE	rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
					AND (dbd.Hours = 0
						OR dbd.Hours IS NULL)
				OR rt.RateTypeCode = @constRateTypeCode_Weekly
					AND (@optProrationMethod = 1
							AND dbd.DayOfWeek IN (1, 7)
						OR @optProrationMethod = 2
							AND (@criUseAttendance = 0
									--If not calculating based on attendance, only HoursPerDay will have
									--correct information for that specific date.  Hours will contain the
									--hours for the schedule detail line
									AND (dbd.HoursPerDay = 0
										OR dbd.HoursPerDay IS NULL)
								OR (@criUseAttendance = 1
									--If calculating based on attendance, Hours will be populated with
									--the number of hours for that day, while HoursPerDay will not be
									AND (dbd.Hours = 0
										OR dbd.Hours IS NULL))))
				OR rt.RateTypeCode = @constRateTypeCode_Monthly
					AND @optProrationMethod = 2 --If using scheduled care, always pay each day
					AND (@criUseAttendance = 0
							--If not calculating based on attendance, only HoursPerDay will have
							--correct information for that specific date.  Hours will contain the
							--hours for the schedule detail line
							AND (dbd.HoursPerDay = 0
								OR dbd.HoursPerDay IS NULL)
						OR (@criUseAttendance = 1
							--If calculating based on attendance, Hours will be populated with
							--the number of hours for that day, while HoursPerDay will not be
							AND (dbd.Hours = 0
								OR dbd.Hours IS NULL)))

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Determine full-time and part-time */
		SELECT	@procDebugMessage = 'Full-time/part-time setting'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		UPDATE	dbd
		SET		CareTimeID =	CASE
									--Hourly and daily
									WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
											AND dbd.HoursPerDay IS NOT NULL
											AND (ft.FTCutoffTypeProviderPayment <> 2
													AND dbd.HoursPerDay >= ft.FTCutoffProviderPayment
												OR ft.FTCutoffTypeProviderPayment = 2
													AND dbd.HoursPerWeek >= ft.FTCutoffProviderPayment)
										THEN @constCareTimeID_FullTime
									WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
											AND dbd.HoursPerDay IS NOT NULL
											AND (ft.FTCutoffTypeProviderPayment <> 2
													AND dbd.HoursPerDay >= ft.PTCutoffProviderPayment
													AND dbd.HoursPerDay < ft.FTCutoffProviderPayment
												OR ft.FTCutoffTypeProviderPayment = 2
													AND dbd.HoursPerWeek >= ft.PTCutoffProviderPayment
													AND dbd.HoursPerWeek < ft.FTCutoffProviderPayment)
										THEN @constCareTimeID_PartTime
									--Weekly and monthly
									WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
											AND dbd.HoursPerWeek IS NOT NULL
											AND (ft.FTCutoffTypeProviderPayment <> 1
													AND dbd.HoursPerWeek >= ft.FTCutoffProviderPayment
												OR ft.FTCutoffTypeProviderPayment = 1
													AND dbd.HoursPerDay >= ft.FTCutoffProviderPayment)
										THEN @constCareTimeID_FullTime
									WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
											AND dbd.HoursPerWeek IS NOT NULL
											AND (ft.FTCutoffTypeProviderPayment <> 1
													AND dbd.HoursPerWeek >= ft.PTCutoffProviderPayment
													AND dbd.HoursPerWeek < ft.FTCutoffProviderPayment
												OR ft.FTCutoffTypeProviderPayment = 1
													AND dbd.HoursPerDay >= ft.PTCutoffProviderPayment
													AND dbd.HoursPerDay < ft.FTCutoffProviderPayment)
										THEN @constCareTimeID_PartTime
									--If not covered by cases above mark for deletion
									ELSE 0
								END
		FROM	#tmpDayByDay dbd
				JOIN tlkpRateType rt (NOLOCK)
					ON dbd.RateTypeID = rt.RateTypeID
				JOIN #tmpFTCutoff ft (NOLOCK)
					ON dbd.ProgramID = ft.ProgramID
		WHERE	(ft.FTCutoffTypeProviderPayment = 0
						AND rt.RateTypeCode = ft.RateTypeCode
					OR ft.FTCutoffTypeProviderPayment = 1
						AND ft.RateTypeCode = @constRateTypeCode_Daily
					OR ft.FTCutoffTypeProviderPayment = 2
						AND ft.RateTypeCode = @constRateTypeCode_Weekly)
				AND ft.EffectiveDate =	(SELECT	MAX(sub.EffectiveDate)
										FROM	#tmpFTCutoff sub (NOLOCK)
										WHERE	sub.EffectiveDate <= dbd.CalendarDate
												AND sub.ProgramID = dbd.ProgramID)
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Remove days which are not indicated as either full-time or part-time */
		SELECT	@procDebugMessage = 'Removal of days with no care time'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		DELETE	dbd
		FROM	#tmpDayByDay dbd
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN tblChild chi (NOLOCK)
					ON sched.ChildID = chi.ChildID
				JOIN tblFamily fam (NOLOCK)
					ON chi.FamilyID = fam.FamilyID
				LEFT JOIN tblProgram prog (NOLOCK)
					ON dbd.ProgramID = prog.ProgramID
		WHERE	ISNULL(dbd.CareTimeID, 0) = 0
				AND (@criOption <> 3
					OR prog.FamilyFeeSchedule = 1)
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Set rate based on whether schedule is full-time or part-time */
		SELECT	@procDebugMessage = 'Rate setting'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		UPDATE	dbd
		SET		Rate =	CASE
							--Part-time
							WHEN dbd.CareTimeID = @constCareTimeID_PartTime
									AND (@criOption <> 3
										OR prog.FamilyFeeSchedule <> 1)
								THEN ISNULL(det.PartTimeRate, 0)
							--Full-time
							WHEN dbd.CareTimeID = @constCareTimeID_FullTime
									AND (@criOption <> 3
										OR prog.FamilyFeeSchedule <> 1)
								THEN ISNULL(det.FullTimeRate, 0)
							--Private/full fee family
							WHEN @criOption = 3
									AND prog.FamilyFeeSchedule = 1
								THEN ISNULL(det.FullFeeRate, 0)
							ELSE 0
						END
		FROM	#tmpDayByDay dbd
				JOIN #tmpScheduleDetail det (NOLOCK)
					ON dbd.ScheduleDetailID = det.ScheduleDetailID
				JOIN #tmpScheduleCopy sched (NOLOCK)
					ON dbd.ScheduleID = sched.ScheduleID
				JOIN tblChild chi (NOLOCK)
					ON sched.ChildID = chi.ChildID
				JOIN tblFamily fam (NOLOCK)
					ON chi.FamilyID = fam.FamilyID
				LEFT JOIN tblProgram prog (NOLOCK)
					ON dbd.ProgramID = prog.ProgramID
		OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Update rate from rate book if rate book is enabled */
		IF @optEnableProviderRateBook = 1
			BEGIN
				SELECT	@procDebugMessage = 'Rate book data insertion into temp table'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Provider payment
				INSERT	#tmpRateBookByDay
					(ScheduleDetailID,
					RateBookDetailID,
					CalendarDate,
					StartDate,
					StopDate,
					RateTypeID,
					PartTimeRate,
					FullTimeRate)
				SELECT	dbd.ScheduleDetailID,
						dbd.RateBookDetailID,
						dbd.CalendarDate,
						--Calculate date each age bracket starts for each child
						DATEADD(DAY, (rbd.StartAge - CONVERT(INT, rbd.StartAge)) * DATEDIFF(DAY, DATEADD(YEAR, rbd.StartAge, chi.BirthDate), DATEADD(YEAR, rbd.StartAge + 1, chi.BirthDate)), DATEADD(YEAR, rbd.StartAge, chi.BirthDate)) AS StartDate,
						--Calculate date each age bracket ends for each child
						DATEADD(DAY, (rbd.StopAge - CONVERT(INT, rbd.StopAge)) * DATEDIFF(DAY, DATEADD(YEAR, rbd.StopAge, chi.BirthDate), DATEADD(YEAR, rbd.StopAge + 1, chi.BirthDate)), DATEADD(YEAR, rbd.StopAge, chi.BirthDate)) AS StopDate,
						rbd.RateTypeID,
						ISNULL(rbd.PartTimeRate,0),
						ISNULL(rbd.FullTimeRate,0)
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleCopy sched
							ON dbd.ScheduleID = sched.ScheduleID
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
						JOIN tblRateBookDetailRate rbd (NOLOCK)
							ON dbd.RateBookDetailID = rbd.RateBookDetailID
						JOIN tblRateBookDetail det (NOLOCK)
							ON rbd.RateBookDetailID = det.RateBookDetailID
						JOIN tlkpRateBookDetailDescription setup (NOLOCK)
							ON det.RateBookDetailDescriptionID = setup.RateBookDetailDescriptionID
				WHERE	dbd.RateBookDetailID IS NOT NULL
						--Use the most current rate book
						AND rbd.EffectiveDate =	(SELECT	MAX(sub.EffectiveDate)
												FROM	tblRateBookDetailRate sub (NOLOCK)
												WHERE	sub.RateBookDetailID = dbd.RateBookDetailID
														AND sub.EffectiveDate <= dbd.CalendarDate)
						--AND rbd.RateTypeID = dbd.RateTypeID
						AND (det.InactiveDate >= dbd.CalendarDate
							OR det.InactiveDate IS NULL)
						AND (setup.InactiveDate >= dbd.CalendarDate
							OR setup.InactiveDate IS NULL)
				OPTION	(KEEP PLAN)

				--Full fee
				INSERT	#tmpFullFeeRateBookByDay
					(ScheduleDetailID,
					FullFeeRateBookDetailID,
					CalendarDate,
					StartDate,
					StopDate,
					RateTypeID,
					FullFeeRate)
				SELECT	dbd.ScheduleDetailID,
						dbd.FullFeeRateBookDetailID,
						dbd.CalendarDate,--Calculate date each age bracket starts for each child
						DATEADD(DAY, (rbd.StartAge - CONVERT(INT, rbd.StartAge)) * DATEDIFF(DAY, DATEADD(YEAR, rbd.StartAge, chi.BirthDate), DATEADD(YEAR, rbd.StartAge + 1, chi.BirthDate)), DATEADD(YEAR, rbd.StartAge, chi.BirthDate)) AS StartDate,
						--Calculate date each age bracket ends for each child
						DATEADD(DAY, (rbd.StopAge - CONVERT(INT, rbd.StopAge)) * DATEDIFF(DAY, DATEADD(YEAR, rbd.StopAge, chi.BirthDate), DATEADD(YEAR, rbd.StopAge + 1, chi.BirthDate)), DATEADD(YEAR, rbd.StopAge, chi.BirthDate)) AS StopDate,
						rbd.RateTypeID,
						ISNULL(rbd.FullFeeRate,0)
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleCopy sched
							ON dbd.ScheduleID = sched.ScheduleID
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
						JOIN tblRateBookDetailRate rbd (NOLOCK)
							ON dbd.FullFeeRateBookDetailID = rbd.RateBookDetailID
						JOIN tblRateBookDetail det (NOLOCK)
							ON rbd.RateBookDetailID = det.RateBookDetailID
						JOIN tlkpRateBookDetailDescription setup (NOLOCK)
							ON det.RateBookDetailDescriptionID = setup.RateBookDetailDescriptionID
				WHERE	dbd.FullFeeRateBookDetailID IS NOT NULL
						--Use the most current rate book
						AND rbd.EffectiveDate =	(SELECT	MAX(sub.EffectiveDate)
												FROM	tblRateBookDetailRate sub (NOLOCK)
												WHERE	sub.RateBookDetailID = dbd.FullFeeRateBookDetailID
														AND sub.EffectiveDate <= dbd.CalendarDate)
						AND rbd.RateTypeID = dbd.RateTypeID
						AND (det.InactiveDate >= dbd.CalendarDate
							OR det.InactiveDate IS NULL)
						AND (setup.InactiveDate >= dbd.CalendarDate
							OR setup.InactiveDate IS NULL)
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

				IF @criDebug = 1
					SELECT	*
					FROM	#tmpRateBookByDay

				--Update rates
				SELECT	@procDebugMessage = 'Rate update from rate book'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Provider payment
				IF @criUseAttendance = 1 AND @optAutoSetRateType = 1
					--Determine appropriate rate type if auto-setting of rate type is turned on
					BEGIN
						--Check whether schedule qualifies for FT monthly
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Monthly,
								RateBookCareTimeID = @constCareTimeID_FullTime
						FROM	#tmpDayByDay dbd
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)
								--Only assign monthly rate if requested by provider
								AND dbd.RateTypeID = @constRateTypeID_Monthly
								--Is care provided each week of the month?
								AND dbd.CareEachWeek = 1
								--Does care average 30 hours or more per week?
								AND dbd.AverageHoursPerWeek >= 30.00

						--Check whether schedule qualifies for PT monthly
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Monthly,
								RateBookCareTimeID = @constCareTimeID_PartTime
						FROM	#tmpDayByDay dbd
								JOIN #tmpScheduleCopy sched (NOLOCK)
									ON dbd.ScheduleID = sched.ScheduleID
								JOIN tblProvider prov (NOLOCK)
									ON sched.ProviderID = prov.ProviderID
								JOIN tlkpProviderType pt (NOLOCK)
									ON prov.ProviderTypeID = pt.ProviderTypeID
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)
								--Only licensed providers can use part-time rates
								AND pt.ProviderTypeExempt = 0
								--Only assign monthly rate if requested by provider
								AND dbd.RateTypeID = @constRateTypeID_Monthly
								--Is care provided each week of the month?
								AND dbd.CareEachWeek = 1
								--Does care average less than 30 hours per week?
								AND dbd.AverageHoursPerWeek < 30.00

						--Check whether schedule qualifies for FT weekly
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Weekly,
								RateBookCareTimeID = @constCareTimeID_FullTime
						FROM	#tmpDayByDay dbd
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)
								--Only assign weekly rate if requested by provider or if qualifications for monthly rate are not met
								AND dbd.RateTypeID IN (@constRateTypeID_Weekly, @constRateTypeID_Monthly)
								--Is care provided for 30 hours or more per week?
								AND (dbd.BookendWeek = 0
										AND dbd.ActualHoursPerWeek >= 30.00
									OR dbd.BookendWeek = 1
										AND dbd.ActualHoursPerWeek >= (30.00 * CONVERT(NUMERIC(3, 2), dbd.ActualDaysPerWeek) / CONVERT(NUMERIC(3, 2), dbd.DaysPerWeek)))

						--Check whether schedule qualifies for PT weekly
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Weekly,
								RateBookCareTimeID = @constCareTimeID_PartTime
						FROM	#tmpDayByDay dbd
								JOIN #tmpScheduleCopy sched (NOLOCK)
									ON dbd.ScheduleID = sched.ScheduleID
								JOIN tblProvider prov (NOLOCK)
									ON sched.ProviderID = prov.ProviderID
								JOIN tlkpProviderType pt (NOLOCK)
									ON prov.ProviderTypeID = pt.ProviderTypeID
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)
								--Only licensed providers can use part-time rates
								AND pt.ProviderTypeExempt = 0
								--Only assign weekly rate if requested by provider or if qualifications for monthly rate are not met
								AND dbd.RateTypeID IN (@constRateTypeID_Weekly, @constRateTypeID_Monthly)
								--Is care provided for less than 30 hours per week?
								AND (dbd.BookendWeek = 0
										AND dbd.ActualHoursPerWeek < 30.00
									OR dbd.BookendWeek = 1
										AND dbd.ActualHoursPerWeek < (30.00 * CONVERT(NUMERIC(3, 2), dbd.ActualDaysPerWeek) / CONVERT(NUMERIC(3, 2), dbd.DaysPerWeek)))
								--Is care provided for 18 hours or more per week?
								AND (dbd.BookendWeek = 0
										AND dbd.ActualHoursPerWeek >= 18.00
									OR dbd.BookendWeek = 1
										AND dbd.ActualHoursPerWeek >= (18.00 * CONVERT(NUMERIC(3, 2), dbd.ActualDaysPerWeek) / CONVERT(NUMERIC(3, 2), dbd.DaysPerWeek)))

						--Check whether schedule qualifies for FT daily
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Daily,
								RateBookCareTimeID = @constCareTimeID_FullTime
						FROM	#tmpDayByDay dbd
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)
								--Only assign daily rate if daily or hourly rate requested by provider or if qualifications for monthly or weekly rate are not met
								--No additional code needed as this should catch all unassigned entries
								--Is care provided for 6 hours or more per day?
								AND dbd.ActualHoursPerDay >= 6.00

						--Any schedules with no rate type/care time assigned will use the PT hourly rate
						UPDATE	dbd
						SET		RateBookRateTypeID = @constRateTypeID_Hourly,
								RateBookCareTimeID = @constCareTimeID_PartTime
						FROM	#tmpDayByDay dbd
						WHERE	(dbd.RateBookRateTypeID IS NULL
									OR dbd.RateBookCareTimeID IS NULL)

						--Set rate type, care time, and rate
						UPDATE	dbd
						SET		RateTypeID = dbd.RateBookRateTypeID,
								CareTimeID = dbd.RateBookCareTimeID,
								Rate =	CASE
											WHEN dbd.RateBookCareTimeID = @constCareTimeID_PartTime
												THEN rbd.PartTimeRate
											ELSE rbd.FullTimeRate
										END
						FROM	#tmpDayByDay dbd
								JOIN #tmpRateBookByDay rbd
									ON dbd.ScheduleDetailID = rbd.ScheduleDetailID
										AND dbd.CalendarDate = rbd.CalendarDate
										AND dbd.RateBookRateTypeID = rbd.RateTypeID
						WHERE	rbd.StartDate <= dbd.CalendarDate
								AND rbd.StopDate > dbd.CalendarDate
						OPTION	(KEEP PLAN)
					END
				ELSE
					UPDATE	dbd
					SET		Rate =	CASE
										WHEN dbd.CareTimeID = @constCareTimeID_PartTime
											THEN rbd.PartTimeRate
										ELSE rbd.FullTimeRate
									END
					FROM	#tmpDayByDay dbd
							JOIN #tmpRateBookByDay rbd
								ON dbd.ScheduleDetailID = rbd.ScheduleDetailID
									AND dbd.CalendarDate = rbd.CalendarDate
					WHERE	rbd.StartDate <= dbd.CalendarDate
							AND rbd.StopDate > dbd.CalendarDate
					OPTION	(KEEP PLAN)

				--Full fee
				UPDATE	dbd
				SET		Rate = rbd.FullFeeRate
				FROM	#tmpDayByDay dbd
						JOIN #tmpFullFeeRateBookByDay rbd
							ON dbd.ScheduleDetailID = rbd.ScheduleDetailID
								AND dbd.CalendarDate = rbd.CalendarDate
				WHERE	rbd.StartDate <= dbd.CalendarDate
						AND rbd.StopDate > dbd.CalendarDate
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		IF @criDebug = 1
			IF @criOption = 1
				BEGIN
					PRINT 'Contents of day-by-day schedule table after hours and rates have been set:'

					SELECT	*
					FROM	#tmpDayByDay
				END

		/* Set family fee rate */
		IF @optIncludeFamilyFees = 1
			BEGIN
				--Populate temp table of fee rates
				IF @criOption = 4
					INSERT	#tmpFeeRates
						(FamilyID,
						EffectiveDate,
						FullTimeFee,
						PartTimeFee)
					SELECT	DISTINCT
							ifh.FamilyID,
							ifh.FamilyFeeEffectiveDate,
							CASE
								WHEN ifh.WaiveFee = 0
									THEN ifh.FullTimeFee
								ELSE 0
							END,
							CASE
								WHEN ifh.WaiveFee = 0
									THEN ifh.PartTimeFee
								ELSE 0
							END
					FROM	#tmpAttendanceCopy tmp
							JOIN tblChild c (NOLOCK)
								ON tmp.ChildID = c.ChildID
							JOIN tblFamily f (NOLOCK)
								ON c.FamilyID = f.FamilyID
							JOIN tblFamilyIncomeFeeHistory ifh (NOLOCK)
								ON c.FamilyID = ifh.FamilyID
					WHERE	ifh.FamilyFeeEffectiveDate <= @procStopDate
							AND ifh.IncomeAssessment <> 2
							AND f.WaiveFee = 0
					OPTION	(KEEP PLAN)
				ELSE				
					INSERT	#tmpFeeRates
						(FamilyID,
						EffectiveDate,
						FullTimeFee,
						PartTimeFee)
					SELECT	DISTINCT
							ifh.FamilyID,
							ifh.FamilyFeeEffectiveDate,
							CASE
								WHEN ifh.WaiveFee = 0
									THEN ifh.FullTimeFee
								ELSE 0
							END,
							CASE
								WHEN ifh.WaiveFee = 0
									THEN ifh.PartTimeFee
								ELSE 0
							END
					FROM	#tmpScheduleCopy tmp
							JOIN tblChild c (NOLOCK)
								ON tmp.ChildID = c.ChildID
							JOIN tblFamily f (NOLOCK)
								ON c.FamilyID = f.FamilyID
							JOIN tblFamilyIncomeFeeHistory ifh (NOLOCK)
								ON c.FamilyID = ifh.FamilyID
					WHERE	ifh.FamilyFeeEffectiveDate <= @procStopDate
							AND ifh.IncomeAssessment <> 2
							AND f.WaiveFee = 0
					OPTION	(KEEP PLAN)

				SELECT	@procDebugMessage = 'Child total hours per day calculation for family fee generation'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Generate list of families paid directly (to be excluded from family fee)
				INSERT	#tmpPayFamily
					(FamilyID)
				SELECT	DISTINCT
						chi.FamilyID
				FROM	#tmpScheduleCopy sched
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
				WHERE	sched.PayFamily = 1
				OPTION	(KEEP PLAN)

				--Total hours per day
				IF @criOption = 4 
					INSERT	#tmpFamilyFee
						(ChildID,
						ProgramID,
						CalendarDate,
						ProviderID,
						Hours,
						CareTimeID)
					SELECT		a.ChildID,
								a.ProgramID,
								a.AttendanceDate,
								a.ProviderID,
								SUM(a.AttendanceHours),
								@constCareTimeID_PartTime
					FROM		#tmpAttendanceCopy a
								JOIN tblChild chi (NOLOCK)
									ON a.ChildID = chi.ChildID
								JOIN tblFamily fam (NOLOCK)
									ON chi.FamilyID = fam.FamilyID
								LEFT JOIN tblProgram prog (NOLOCK)
									ON a.ProgramID = prog.ProgramID
					WHERE		--Exclude private/full fee families
								prog.FamilyFeeSchedule <> 1
					GROUP BY	a.ChildID,
								a.ProgramID,
								a.AttendanceDate,
								a.ProviderID
					OPTION		(KEEP PLAN)
				ELSE				
					INSERT	#tmpFamilyFee
						(ChildID,
						ProgramID,
						CalendarDate,
						ProviderID,
						Hours,
						HoursPerWeek,
						DaysPerWeek,
						DaysPerMonth,
						CareTimeID)
					SELECT		sched.ChildID,
								dbd.ProgramID,
								dbd.CalendarDate,
								sched.ProviderID,
								SUM(dbd.Hours),
								hpw.HoursPerWeek,
								dbd.DaysPerWeekFamilyFee,
								dbd.DaysPerMonthFamilyFee,
								@constCareTimeID_PartTime
					FROM		#tmpDayByDay dbd
								JOIN #tmpScheduleCopy sched
									ON dbd.ScheduleID = sched.ScheduleID
								JOIN tblChild chi (NOLOCK)
									ON sched.ChildID = chi.ChildID
								JOIN tblFamily fam (NOLOCK)
									ON chi.FamilyID = fam.FamilyID
								JOIN #tmpScheduleDetailDay sdd
									ON dbd.ScheduleDetailID = sdd.ScheduleDetailID
										AND dbd.DayOfWeek = sdd.DayID
								JOIN #tmpScheduleDetail det
									ON sdd.ScheduleDetailID = det.ScheduleDetailID									
								JOIN	(SELECT		sub.ChildID,
													sub.ProgramID,
													sub.CalendarDate,
													SUM(sub.HoursPerWeek) AS HoursPerWeek
										FROM		(SELECT	DISTINCT
															tdbd.ScheduleID,
															s.ChildID,
															tdbd.ProgramID,
															tdbd.CalendarDate,
															tdbd.HoursPerWeek
													FROM	#tmpDayByDay tdbd (NOLOCK)
															JOIN #tmpScheduleCopy s (NOLOCK)
																ON tdbd.ScheduleID = s.ScheduleID) sub
										GROUP BY	sub.ChildID,
													sub.ProgramID,
													sub.CalendarDate) hpw
									ON sched.ChildID = hpw.ChildID
										AND dbd.ProgramID = hpw.ProgramID
										AND dbd.CalendarDate = hpw.CalendarDate
								LEFT JOIN tblProgram prog (NOLOCK)
									ON dbd.ProgramID = prog.ProgramID
								LEFT JOIN #tmpPayFamily pf
									ON chi.FamilyID = pf.FamilyID
					WHERE		pf.FamilyID IS NULL
								--Exclude private/full fee families
								AND prog.FamilyFeeSchedule <> 1
								AND det.FixedFee = 0
					GROUP BY	sched.ChildID,
								dbd.ProgramID,
								dbd.CalendarDate,
								sched.ProviderID,
								hpw.HoursPerWeek,
								dbd.DaysPerWeekFamilyFee,
								dbd.DaysPerMonthFamilyFee
					OPTION		(KEEP PLAN)

				--Set effective date for family fees
				UPDATE	ff
				SET		EffectiveDate = sub.EffectiveDate
				FROM	#tmpFamilyFee ff
						JOIN	(SELECT		ff.ChildID,
											ff.CalendarDate,
											MAX(fr.EffectiveDate) AS EffectiveDate
								FROM		#tmpFamilyFee ff
											JOIN tblChild c (NOLOCK)
												ON ff.ChildID = c.ChildID
											JOIN #tmpFeeRates fr
												ON c.FamilyID = fr.FamilyID
													AND ff.CalendarDate >= fr.EffectiveDate
								GROUP BY	ff.ChildID,
											ff.CalendarDate) sub
							ON ff.ChildID = sub.ChildID
								AND ff.CalendarDate = sub.CalendarDate
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

				--Set rate and whether care is full-time or part-time
				SELECT	@procDebugMessage = 'Family fee rate setting'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				UPDATE	ff
				SET		RateTypeID = @constRateTypeID_Daily
				FROM	#tmpFamilyFee ff
						JOIN tblChild chi (NOLOCK)
							ON ff.ChildID = chi.ChildID
						LEFT JOIN #tmpFeeRates fr (NOLOCK)
							ON chi.FamilyID = fr.FamilyID
								AND ff.EffectiveDate = fr.EffectiveDate
				OPTION	(KEEP PLAN)

				UPDATE	ff
				SET		CareTimeID =	CASE
											--Hourly and daily
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
													AND ff.Hours IS NOT NULL
													AND (ft.FTCutoffTypeFamilyFee <> 2
															AND ff.Hours >= ft.FTCutoffFamilyFee
														OR ft.FTCutoffTypeFamilyFee = 2
															AND ff.HoursPerWeek >= ft.FTCutoffFamilyFee)
												THEN @constCareTimeID_FullTime
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
													AND ff.Hours IS NOT NULL
													AND (ft.FTCutoffTypeFamilyFee <> 2
															AND ff.Hours >= ft.PTCutoffFamilyFee
															AND ff.Hours < ft.FTCutoffFamilyFee
														OR ft.FTCutoffTypeFamilyFee = 2
															AND ff.HoursPerWeek >= ft.PTCutoffFamilyFee
															AND ff.HoursPerWeek < ft.FTCutoffFamilyFee)
												THEN @constCareTimeID_PartTime
											--Weekly
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
													AND ff.HoursPerWeek IS NOT NULL
													AND (ft.FTCutoffTypeFamilyFee <> 1
															AND ff.HoursPerWeek >= ft.FTCutoffFamilyFee
														OR ft.FTCutoffTypeFamilyFee = 1
															AND ff.Hours >= ft.FTCutoffFamilyFee)
												THEN @constCareTimeID_FullTime
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
													AND ff.HoursPerWeek IS NOT NULL
													AND (ft.FTCutoffTypeFamilyFee <> 1
															AND ff.HoursPerWeek >= ft.PTCutoffFamilyFee
															AND ff.HoursPerWeek < ft.FTCutoffFamilyFee
														OR ft.FTCutoffTypeFamilyFee = 1
															AND ff.Hours >= ft.PTCutoffFamilyFee
															AND ff.Hours < ft.FTCutoffFamilyFee)
												THEN @constCareTimeID_PartTime
											--If not covered by cases above mark for deletion
											ELSE 0
										END
				FROM	#tmpFamilyFee ff
						JOIN tlkpRateType rt (NOLOCK)
							ON ff.RateTypeID = rt.RateTypeID
						JOIN #tmpFTCutoff ft (NOLOCK)
							ON ff.ProgramID = ft.ProgramID
				WHERE	(ft.FTCutoffTypeFamilyFee = 0
								AND rt.RateTypeCode = ft.RateTypeCode
							OR ft.FTCutoffTypeFamilyFee = 1
								AND ft.RateTypeCode = @constRateTypeCode_Daily
							OR ft.FTCutoffTypeFamilyFee = 2
								AND ft.RateTypeCode = @constRateTypeCode_Weekly)
						AND ft.EffectiveDate =	(SELECT	MAX(sub.EffectiveDate)
												FROM	#tmpFTCutoff sub (NOLOCK)
												WHERE	sub.EffectiveDate <= ff.CalendarDate
														AND sub.ProgramID = ff.ProgramID)
				OPTION	(KEEP PLAN)

				UPDATE	ff
				SET		Rate =	CASE CareTimeID
									WHEN @constCareTimeID_FullTime
										THEN fr.FullTimeFee
									WHEN @constCareTimeID_PartTime
										THEN fr.PartTimeFee
								END
				FROM	#tmpFamilyFee ff
						JOIN tblChild chi (NOLOCK)
							ON ff.ChildID = chi.ChildID
						LEFT JOIN #tmpFeeRates fr (NOLOCK)
							ON chi.FamilyID = fr.FamilyID
								AND ff.EffectiveDate = fr.EffectiveDate
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

				--Delete days with no care
				SELECT	@procDebugMessage = 'Removal of days with no care'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				DELETE	ff
				FROM	#tmpFamilyFee ff
						JOIN tlkpRateType rt (NOLOCK)
							ON ff.RateTypeID = rt.RateTypeID
				WHERE	ff.Hours = 0
						AND rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

				--Delete records with no rate set (fees are 0 or waived for these families)
				SELECT	@procDebugMessage = 'Removal of records with no rate'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				DELETE	#tmpFamilyFee
				WHERE	Rate IS NULL
						OR Rate = 0
				OPTION	(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

				IF @criDebug = 1
					SELECT	*
					FROM	#tmpFamilyFee
			END

		/* Set rate from attendance information */
		--This is done as a final step before calculation of results, overriding everything else (except final RMR validation)
		--Should not be done if rate book is used
		IF @criUseAttendance = 1
			BEGIN
				SELECT	@procDebugMessage = 'Rate book data insertion into temp table'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				UPDATE	#tmpDayByDay
				SET		RateTypeID = AttendanceRateTypeID,
						Rate =	CASE
									--Part-time
									WHEN CareTimeID = @constCareTimeID_PartTime
											AND @criOption <> 3
										THEN ISNULL(AttendancePartTimeRate, 0)
									--Full-time
									WHEN CareTimeID = @constCareTimeID_FullTime
											AND @criOption <> 3
										THEN ISNULL(AttendanceFullTimeRate, 0)
								END
				WHERE	RateBookDetailID IS NULL

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Perform RMR validation */
		IF @optRMROverride <> 1 AND @criOption <> 3 AND @optPerformRMRValidation = 1
			BEGIN
				SELECT	@procDebugMessage = 'RMR validation'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Get schedule list
				INSERT	#tmpScheduleEveningWeekend
					(ScheduleID,
					ChildID,
					BirthDate,
					ProviderID,
					StartDate,
					StopDate,
					WeeklyHours,
					WeeklyHoursRegular,
					WeeklyHoursVacation,
					ScheduleEffectiveDate,
					CalendarDate,
					PaymentTypeCode,
					SpecialNeeds,
					SpecialNeedsRMRMultiplier,
					Weekend,
					Evening,
					ExceptionalNeeds,
					SeverelyHandicapped)
				SELECT		s.ScheduleID,
							s.ChildID,
							c.BirthDate,
							s.ProviderID,
							s.StartDate,
							s.StopDate,
							CASE pt.PaymentTypeCode
								WHEN '01'
									THEN s.WeeklyHoursRegular
								WHEN '02'
									THEN s.WeeklyHoursVacation
							END,
							s.WeeklyHoursRegular,
							s.WeeklyHoursVacation,
							cal.CalendarDate,
							cal.CalendarDate,
							pt.PaymentTypeCode,
							dbo.ChildHasSpecialNeed(s.ChildID, NULL, cal.CalendarDate, cal.CalendarDate),
							CONVERT(TINYINT, s.SpecialNeedsRMRMultiplier),
							MAX(CONVERT(TINYINT, sd.Weekend)),
							MAX(CONVERT(TINYINT, sd.Evening)),
							dbo.ChildHasSpecialNeed(s.ChildID, '22', cal.CalendarDate, cal.CalendarDate),
							dbo.ChildHasSpecialNeed(s.ChildID, '24', cal.CalendarDate, cal.CalendarDate)
				FROM 		tblScheduleDetail sd (NOLOCK)
							JOIN #tmpDayByDay dbd (NOLOCK)
								ON sd.ScheduleDetailID = dbd.ScheduleDetailID
									AND sd.ScheduleID = dbd.ScheduleID
							JOIN tblCalendar cal (NOLOCK)
								ON DATEPART(MONTH,dbd.CalendarDate) = DATEPART(MONTH,cal.CalendarDate)
									AND DATEPART(YEAR,dbd.CalendarDate) = DATEPART(YEAR,cal.CalendarDate)																		
							JOIN #tmpScheduleCopy s (NOLOCK)
								ON sd.ScheduleID = s.ScheduleID
									AND dbd.ScheduleID = s.ScheduleID
							JOIN tlkpPaymentType pt (NOLOCK)
								ON sd.PaymentTypeID = pt.PaymentTypeID
							JOIN tblChild c (NOLOCK) 
								ON s.ChildID = c.ChildID
							JOIN tblFamily f (NOLOCK)
								ON c.FamilyID = f.FamilyID
							JOIN tblProvider p (NOLOCK)
								ON s.ProviderID = p.ProviderID
				GROUP BY	s.ScheduleID,
							s.ChildID,
							c.BirthDate,
							s.ProviderID,
							s.StartDate,
							s.StopDate,
							CASE pt.PaymentTypeCode
								WHEN '01'
									THEN s.WeeklyHoursRegular
								WHEN '02'
									THEN s.WeeklyHoursVacation
							END,
							s.WeeklyHoursRegular,
							s.WeeklyHoursVacation,
							cal.CalendarDate,
							pt.PaymentTypeCode,
							CONVERT(TINYINT, s.SpecialNeedsRMRMultiplier)

				--Get schedule detail
				INSERT #tmpScheduleDetailRMR
					(ScheduleDetailID,
					ScheduleID,
					ScheduleEffectiveDate,
					RMRDescriptionID,
					ProviderTypeID,
					PaymentTypeID,
					StartTime,
					StopTime,
					Hours,
					WeeklyHours,
					RateTypeID,
					CareTimeCode,
					Rate)
				SELECT	DISTINCT
						det.ScheduleDetailID,
						det.ScheduleID,
						dbd.CalendarDate,
						CASE pg.UseProviderRMR
							WHEN 0
								THEN pg.RMRDescriptionID 
							ELSE p.RMRDescriptionID
						END,
						p.ProviderTypeID,
						det.PaymentTypeID,
						det.StartTime,
						det.StopTime,
						det.Hours,
						det.WeeklyHours,
						dbd.RateTypeID,
						CASE
							WHEN dbd.CareTimeID = @constCareTimeID_FullTime
								THEN '01'
							WHEN dbd.CareTimeID = @constCareTimeID_PartTime
								THEN '02'
						END,
						dbd.Rate
				FROM	tblScheduleDetail det (NOLOCK)
						JOIN #tmpDayByDay dbd (NOLOCK)
							ON det.ScheduleDetailID = dbd.ScheduleDetailID
						JOIN #tmpScheduleEveningWeekend s (NOLOCK)
							ON det.ScheduleID = s.ScheduleID
								AND dbd.ScheduleID = s.ScheduleID
								AND dbd.CalendarDate = s.ScheduleEffectiveDate
						JOIN tblProvider p (NOLOCK)
							ON s.ProviderID = p.ProviderID
						LEFT JOIN tblProgram pg (NOLOCK)
							ON dbd.ProgramID = pg.ProgramID
				WHERE	dbd.Rate IS NOT NULL

				--Determine RMR
				EXEC spValidateRMR 0

				--Cap rate at RMR
				UPDATE	dbd
				SET		Rate = rmr.MarketRate,
						@procRMRCapped = 1
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleDetailRMR rmr (NOLOCK)
							ON dbd.ScheduleDetailID = rmr.ScheduleDetailID
								AND dbd.CalendarDate = rmr.ScheduleEffectiveDate
				WHERE	(dbd.CareTimeID = @constCareTimeID_FullTime
								AND rmr.CareTimeCode = '01'
							OR dbd.CareTimeID = @constCareTimeID_PartTime
								AND rmr.CareTimeCode = '02')
						AND dbd.Rate > rmr.MarketRate

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Insert into result table */
		--Time sheet/provider payment, projection, private/full fee family fee

		--Rather than inserting results based on rate type, results will
		--be inserted based on the summary method chosen.  The units and total
		--will be set based on the rate type.  Monthly rate types can only be
		--inserted using the monthly summary.  Projection will always insert
		--a monthly summary

		--Daily summary
		--Insert an individual record for each day for payments using
		--the hourly, daily, or weekly rate type
		--Weekly rate type is excluded if the scheduled days proration method is selected;
		--in this case weekly rates will summarize results by week to avoid difficulties in determining
		--the proper number of days per week
		--Monthly rate type is excluded due to rounding issues
		SELECT	@procDebugMessage = 'Insertion of daily summary results to data table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		INSERT	#tmpResult
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			ExtendedSchedule,
			StartDate,
			StopDate,
			Evening,
			Weekend,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			Breakfast,
			Lunch,
			Snack,
			Dinner)
		SELECT		chi.FamilyID,
					chi.ChildID,
					dbd.ProgramID,
					dbd.ScheduleID,
					dbd.ScheduleDetailID,
					sched.ProviderID,
					CONVERT(TINYINT, dbd.ExtendedSchedule),
					dbd.CalendarDate,
					dbd.CalendarDate,
					CONVERT(TINYINT, dbd.Evening),
					CONVERT(TINYINT, dbd.Weekend),
					dbd.PaymentTypeID,
					dbd.RateTypeID,
					dbd.CareTimeID,
					CASE
						WHEN @criOption = 3 AND CONVERT(TINYINT, sched.SiblingDiscount) = 1
							THEN dbd.Rate * (1.00 - @optSiblingDiscountPercentage)
						ELSE dbd.Rate
					END,
					--Units
					SUM	(CASE
							WHEN rt.RateTypeCode = @constRateTypeCode_Hourly
								THEN dbd.Hours
							WHEN rt.RateTypeCode = @constRateTypeCode_Daily
								THEN 1
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
								--Number of units is .2 units per weekday.  This is not dependent on
								--whether care was received those days, but whether the schedule was
								--in effect those days
								THEN .2
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
								THEN 1 / dbd.DaysPerWeek
						END),
					--Total
					CASE
						WHEN @criOption = 3 AND CONVERT(TINYINT, sched.SiblingDiscount) = 1
							THEN (1.00 - @optSiblingDiscountPercentage)
						ELSE 1.00
					END * SUM	(CASE
									WHEN rt.RateTypeCode = @constRateTypeCode_Hourly
										THEN ROUND(dbd.Rate * dbd.Hours, 2)
									WHEN rt.RateTypeCode = @constRateTypeCode_Daily
										THEN ROUND(dbd.Rate, 2)
									WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
										THEN ROUND(dbd.Rate * .2, 2)
									WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
										THEN ROUND(dbd.Rate / dbd.DaysPerWeek, 2)
								END),
					MAX(CONVERT(TINYINT, dbd.Breakfast)),
					MAX(CONVERT(TINYINT, dbd.Lunch)),
					MAX(CONVERT(TINYINT, dbd.Snack)),
					MAX(CONVERT(TINYINT, dbd.Dinner))
		FROM		#tmpDayByDay dbd
					JOIN tlkpRateType rt (NOLOCK)
						ON dbd.RateTypeID = rt.RateTypeID
					JOIN #tmpScheduleCopy sched
						ON dbd.ScheduleID = sched.ScheduleID
							AND dbd.ExtendedSchedule = sched.ExtendedSchedule
					JOIN tblChild chi (NOLOCK)
						ON sched.ChildID = chi.ChildID
					JOIN tblFamily fam (NOLOCK)
						ON chi.FamilyID = fam.FamilyID
					LEFT JOIN tblProgram prog (NOLOCK)
						ON dbd.ProgramID = prog.ProgramID
		WHERE		--Insert records if full detail is chosen
					(@optPaymentDetailSummary = 1
							--and the rate type is hourly or daily
							AND rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
						--or daily summary is chosen
						OR @optPaymentDetailSummary = 2
							--and the rate type is not monthly
							AND rt.RateTypeCode <> @constRateTypeCode_Monthly
							--and the rate type is not weekly
							AND (rt.RateTypeCode <> @constRateTypeCode_Weekly
								--or calendar days proration method is selected
								OR @optProrationMethod = 1))
					--Also determine which days to exclude
					--For hourly and daily rate types:
					AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
							--Exclude days with no care
							--AND dbd.Hours > 0
						--For weekly rate type:
						OR rt.RateTypeCode = @constRateTypeCode_Weekly
							--Exclude weekends when based on calendar proration method
							AND (@optProrationMethod = 1
									AND dbd.DayOfWeek > 1
									AND dbd.DayOfWeek < 7
								OR @optProrationMethod = 2))
					--Most family fee calculation is handled separately,
					--except for private/full fee families
					AND (@criOption <> 3
						OR prog.FamilyFeeSchedule = 1)
					--Make sure day is marked to be paid
					AND dbd.PayChargeForDay = 1
		GROUP BY	chi.FamilyID,
					chi.ChildID,
					dbd.ProgramID,
					dbd.ScheduleID,
					dbd.ScheduleDetailID,
					sched.ProviderID,
					CONVERT(TINYINT, sched.SiblingDiscount),
					CONVERT(TINYINT, dbd.ExtendedSchedule),
					dbd.CalendarDate,
					dbd.CalendarDate,
					CONVERT(TINYINT, dbd.Evening),
					CONVERT(TINYINT, dbd.Weekend),
					dbd.PaymentTypeID,
					dbd.RateTypeID,
					dbd.CareTimeID,
					dbd.Rate
		OPTION		(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		--Weekly summary
		--Insert a record for each week for payments using
		--the hourly, daily, or weekly rate type
		--Monthly rate type is excluded due to rounding issues
		SELECT	@procDebugMessage = 'Insertion of weekly summary results to data table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		INSERT	#tmpResult
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			ExtendedSchedule,
			StartDate,
			StopDate,
			Evening,
			Weekend,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			Breakfast,
			Lunch,
			Snack,
			Dinner)
		SELECT		wk.FamilyID,
					wk.ChildID,
					wk.ProgramID,
					wk.ScheduleID,
					wk.ScheduleDetailID,
					wk.ProviderID,
					wk.ExtendedSchedule,
					wk.WeekStart,
					wk.WeekStop,
					wk.Evening,
					wk.Weekend,
					wk.PaymentTypeID,
					wk.RateTypeID,
					wk.CareTimeID,
					wk.Rate,
					--Units
					SUM	(CASE
							WHEN wk.RateTypeCode = @constRateTypeCode_Hourly
								THEN wk.Hours
							WHEN wk.RateTypeCode = @constRateTypeCode_Daily
								THEN 1
							WHEN wk.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
								--Number of units is .2 units per weekday.  This is not dependent on
								--whether care was received those days, but whether the schedule was
								--in effect those days
								THEN .2
							WHEN wk.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
								THEN daysperweek.ActualDaysInWeek / wk.DaysPerWeek
						END),
					--Total
					ROUND(SUM	(CASE
									WHEN wk.RateTypeCode = @constRateTypeCode_Hourly
										THEN wk.Hours
									WHEN wk.RateTypeCode = @constRateTypeCode_Daily
										THEN 1
									WHEN wk.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
										--Number of units is .2 units per weekday.  This is not dependent on
										--whether care was received those days, but whether the schedule was
										--in effect those days
										THEN .2
									WHEN wk.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
										THEN daysperweek.ActualDaysInWeek / wk.DaysPerWeek
								END) * wk.Rate, 2),
					MAX(CONVERT(TINYINT, wk.Breakfast)),
					MAX(CONVERT(TINYINT, wk.Lunch)),
					MAX(CONVERT(TINYINT, wk.Snack)),
					MAX(CONVERT(TINYINT, wk.Dinner))
		FROM		--Use schedule start date as start date of record if later than the
					--week start date, and use schedule stop date if earlier than the
					--week stop date
					(SELECT	DISTINCT
							chi.FamilyID,
							chi.ChildID,
							dbd.ProgramID,
							dbd.ScheduleID,
							dbd.ScheduleDetailID,
							sched.ProviderID,
							CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
							CASE
								WHEN rt.RateTypeCode <> @constRateTypeCode_Weekly OR @optProrationMethod = 1
									THEN dbd.CalendarDate
								ELSE NULL
							END AS CalendarDate,
							CASE
								WHEN sched.StartDate > dbd.WeekStart
									THEN sched.StartDate
								ELSE dbd.WeekStart
							END AS WeekStart,
							CASE
								WHEN sched.StopDate < dbd.WeekStop
									THEN sched.StopDate
								ELSE dbd.WeekStop
							END AS WeekStop,
							CONVERT(TINYINT, dbd.Evening) AS Evening,
							CONVERT(TINYINT, dbd.Weekend) AS Weekend,
							dbd.PaymentTypeID,
							dbd.RateTypeID,
							rt.RateTypeCode,
							dbd.CareTimeID,
							dbd.DaysPerWeek,
							--Only include hours for hourly or daily rates
							CASE
								WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
									THEN dbd.Hours
								ELSE NULL
							END AS Hours,
							CASE
								WHEN @criOption = 3 AND sched.SiblingDiscount = 1
									THEN dbd.Rate * (1.00 - @optSiblingDiscountPercentage)
								ELSE dbd.Rate
							END AS Rate,
							dbd.Breakfast,
							dbd.Lunch,
							dbd.Snack,
							dbd.Dinner
					FROM	#tmpDayByDay dbd
							JOIN tlkpRateType rt (NOLOCK)
								ON dbd.RateTypeID = rt.RateTypeID
							JOIN #tmpScheduleCopy sched
								ON dbd.ScheduleID = sched.ScheduleID
									AND dbd.ExtendedSchedule = sched.ExtendedSchedule
							JOIN tblChild chi (NOLOCK)
								ON sched.ChildID = chi.ChildID
							JOIN tblFamily fam (NOLOCK)
								ON chi.FamilyID = fam.FamilyID
							LEFT JOIN tblProgram prog (NOLOCK)
								ON dbd.ProgramID = prog.ProgramID
					WHERE	--Insert records if full detail is chosen
							(@optPaymentDetailSummary = 1
									--and the rate type is weekly
									AND rt.RateTypeCode = @constRateTypeCode_Weekly
								--or daily summary is chosen
								OR @optPaymentDetailSummary = 2
									--and the rate type is weekly
									AND rt.RateTypeCode = @constRateTypeCode_Weekly
									--and the scheduled days proration method is selected
									AND @optProrationMethod = 2
								--or weekly summary is chosen
								OR @optPaymentDetailSummary = 3
									--and the rate type is not monthly
									AND rt.RateTypeCode <> @constRateTypeCode_Monthly)
							--Also determine which days to exclude
							--For hourly and daily rate types:
							AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
									--Exclude days with no care
									AND dbd.Hours > 0
								--For weekly rate type:
								OR rt.RateTypeCode = @constRateTypeCode_Weekly
									--Exclude weekends when based on scheduled care
									AND (@optProrationMethod = 1
											AND dbd.DayOfWeek > 1
											AND dbd.DayOfWeek < 7
										OR @optProrationMethod = 2))
							--Most family fee calculation is handled separately,
							--except for private/full fee families
							AND (@criOption <> 3
								OR prog.FamilyFeeSchedule = 1)
							--Make sure day is marked to be paid
							AND dbd.PayChargeForDay = 1) wk
					JOIN	(SELECT		dbd.ScheduleID,
										CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
										dbd.ProgramID,
										dbd.RateTypeID,
										dbd.PaymentTypeID,
										CASE
											WHEN sched.StartDate > dbd.WeekStart
												THEN sched.StartDate
											ELSE dbd.WeekStart
										END AS WeekStart,
										CASE
											WHEN sched.StopDate < dbd.WeekStop
												THEN sched.StopDate
											ELSE dbd.WeekStop
										END AS WeekStop,
										COUNT(DISTINCT dbd.CalendarDate) AS ActualDaysInWeek
							FROM		#tmpDayByDay dbd
										JOIN tlkpRateType rt (NOLOCK)
											ON dbd.RateTypeID = rt.RateTypeID
										JOIN #tmpScheduleCopy sched
											ON dbd.ScheduleID = sched.ScheduleID
												AND dbd.ExtendedSchedule = sched.ExtendedSchedule
										LEFT JOIN tblProgram prog (NOLOCK)
											ON dbd.ProgramID = prog.ProgramID
							WHERE		--Insert records if full detail is chosen
										(@optPaymentDetailSummary = 1
												--and the rate type is weekly
												AND rt.RateTypeCode = @constRateTypeCode_Weekly
											--or daily summary is chosen
											OR @optPaymentDetailSummary = 2
												--and the rate type is weekly
												AND rt.RateTypeCode = @constRateTypeCode_Weekly
												--and the scheduled days proration method is selected
												AND @optProrationMethod = 2
											--or weekly summary is chosen
											OR @optPaymentDetailSummary = 3
												--and the rate type is not monthly
												AND rt.RateTypeCode <> @constRateTypeCode_Monthly)
										--Also determine which days to exclude
										--For hourly and daily rate types:
										AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
												--Exclude days with no care
												AND dbd.Hours > 0
											--For weekly rate type:
											OR rt.RateTypeCode = @constRateTypeCode_Weekly
												--Exclude weekends when based on scheduled care
												AND (@optProrationMethod = 1
														AND dbd.DayOfWeek > 1
														AND dbd.DayOfWeek < 7
													OR @optProrationMethod = 2))
										--Most family fee calculation is handled separately,
										--except for private/full fee families
										AND (@criOption <> 3
											OR prog.FamilyFeeSchedule = 1)
										--Make sure day is marked to be paid
										AND dbd.PayChargeForDay = 1
							GROUP BY	dbd.ScheduleID,
										CONVERT(TINYINT, dbd.ExtendedSchedule),
										dbd.ProgramID,
										dbd.RateTypeID,
										dbd.PaymentTypeID,
										CASE
											WHEN sched.StartDate > dbd.WeekStart
												THEN sched.StartDate
											ELSE dbd.WeekStart
										END,
										CASE
											WHEN sched.StopDate < dbd.WeekStop
												THEN sched.StopDate
											ELSE dbd.WeekStop
										END) daysperweek
						ON wk.ScheduleID = daysperweek.ScheduleID
							AND wk.ExtendedSchedule = daysperweek.ExtendedSchedule
							AND wk.ProgramID = daysperweek.ProgramID
							AND wk.RateTypeID = daysperweek.RateTypeID
							AND wk.PaymentTypeID = daysperweek.PaymentTypeID
							AND wk.WeekStart = daysperweek.WeekStart
							AND wk.WeekStop = daysperweek.WeekStop
		GROUP BY	wk.FamilyID,
					wk.ChildID,
					wk.ProgramID,
					wk.ScheduleID,
					wk.ScheduleDetailID,
					wk.ProviderID,
					wk.ExtendedSchedule,
					wk.WeekStart,
					wk.WeekStop,
					wk.Evening,
					wk.Weekend,
					wk.PaymentTypeID,
					wk.RateTypeID,
					wk.CareTimeID,
					wk.Rate
		OPTION		(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		--Monthly summary
		--Total all payments by month
		--Monthly rate type will only be inserted here,
		--regardless of summary option chosen, to prevent rounding issues
		SELECT	@procDebugMessage = 'Insertion of monthly summary results to data table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		INSERT	#tmpResult
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			ExtendedSchedule,
			StartDate,
			StopDate,
			Evening,
			Weekend,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			Breakfast,
			Lunch,
			Snack,
			Dinner)
		SELECT		mon.FamilyID,
					mon.ChildID,
					mon.ProgramID,
					mon.ScheduleID,
					mon.ScheduleDetailID,
					mon.ProviderID,
					mon.ExtendedSchedule,
					mon.MonthStart,
					mon.MonthStop,
					mon.Evening,
					mon.Weekend,
					mon.PaymentTypeID,
					mon.RateTypeID,
					mon.CareTimeID,
					mon.Rate,
					--Units
					CASE
						WHEN mon.RateTypeCode = @constRateTypeCode_Hourly
							THEN CONVERT(NUMERIC (5, 2), SUM(mon.Hours))
						WHEN mon.RateTypeCode = @constRateTypeCode_Daily
							THEN CONVERT(NUMERIC (5, 2), SUM(1))
						WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
							THEN CONVERT(NUMERIC (5, 2), SUM(.2))
						WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
							THEN CONVERT(NUMERIC (5, 2), SUM(rates.ActualDaysInMonth) / SUM(mon.DaysPerWeek))
						WHEN mon.RateTypeCode = @constRateTypeCode_Monthly
							--Each day in the month counts for a fraction of one monthly unit.
							--**For scheduled care, this fraction is determined by dividing 1 by the number of days
							--in the month.  Whether a day counts toward the total number of units
							--is determined by whether the schedule was in effect on that day,
							--not whether case was scheduled for that specific day.  For example,
							--if a schedule runs from November 1st through November 20th, the total
							--units for a monthly schedule would be equal to 20/30, or approximately
							--0.6667, even if care is only scheduled on Mondays and Wednesdays.
							--**For attendance, it's determined by dividing 1 by the number of days
							--of care scheduled for the month.  In this case, whether a day counts toward
							--the total number of units WILL depend on whether there was care scheduled that day.
							THEN CONVERT(NUMERIC (5, 2), rates.ActualDaysInMonth / mon.DaysInMonth)
					END AS Units,
					--Total
					CASE
						WHEN mon.RateTypeCode = @constRateTypeCode_Hourly
							THEN SUM(mon.Hours * mon.Rate)
						WHEN mon.RateTypeCode = @constRateTypeCode_Daily
							THEN SUM(mon.Rate)
						WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
							THEN SUM(.2 * mon.Rate)
						WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
							THEN ROUND(SUM(rates.ActualDaysInMonth) / SUM(mon.DaysPerWeek), 2) * mon.Rate
						WHEN mon.RateTypeCode = @constRateTypeCode_Monthly
							THEN ROUND(rates.ActualDaysInMonth / mon.DaysInMonth, 2) * mon.Rate
					END AS Total,
					MAX(CONVERT(TINYINT, mon.Breakfast)),
					MAX(CONVERT(TINYINT, mon.Lunch)),
					MAX(CONVERT(TINYINT, mon.Snack)),
					MAX(CONVERT(TINYINT, mon.Dinner))
		FROM		--Use schedule start date as start date of record if later than the
					--month start date, and use schedule stop date if earlier than the
					--month stop date
					(SELECT	DISTINCT
							chi.FamilyID,
							chi.ChildID,
							dbd.ProgramID,
							dbd.ScheduleID,
							dbd.ScheduleDetailID,
							sched.ProviderID,
							CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
							CASE
								WHEN rt.RateTypeCode NOT IN (@constRateTypeCode_Weekly, @constRateTypeCode_Weekly) OR (rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1)
									THEN dbd.CalendarDate
								ELSE NULL
							END AS CalendarDate,
							CONVERT(NUMERIC (3, 2), dbd.DaysPerWeek) AS DaysPerWeek,
							CASE
								WHEN sched.StartDate > dbd.MonthStart
									THEN sched.StartDate
								ELSE dbd.MonthStart
							END AS MonthStart,
							CASE
								WHEN sched.StopDate < dbd.MonthStop
									THEN sched.StopDate
								ELSE dbd.MonthStop
							END AS MonthStop,
							CASE
								WHEN @optProrationMethod = 1
									THEN CONVERT(NUMERIC (4, 2), DATEPART(DAY, dbd.MonthStop))
								WHEN @optProrationMethod = 2
									THEN CONVERT(NUMERIC (4, 2), dbd.DaysPerMonth)
							END AS DaysInMonth,
							CONVERT(TINYINT, dbd.Evening) AS Evening,
							CONVERT(TINYINT, dbd.Weekend) AS Weekend,
							dbd.PaymentTypeID,
							dbd.RateTypeID,
							rt.RateTypeCode,
							dbd.CareTimeID,
							CASE
								WHEN @criOption = 3 AND sched.SiblingDiscount = 1
									THEN dbd.Rate * (1.00 - @optSiblingDiscountPercentage)
								ELSE dbd.Rate
							END AS Rate,
							--Only include hours for hourly or daily rates
							CASE
								WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
									THEN dbd.Hours
								ELSE NULL
							END AS Hours,
							dbd.Breakfast,
							dbd.Lunch,
							dbd.Snack,
							dbd.Dinner
					FROM	#tmpDayByDay dbd
							JOIN tlkpRateType rt (NOLOCK)
								ON dbd.RateTypeID = rt.RateTypeID
							JOIN #tmpScheduleCopy sched
								ON dbd.ScheduleID = sched.ScheduleID
									AND dbd.ExtendedSchedule = sched.ExtendedSchedule
							JOIN tblChild chi (NOLOCK)
								ON sched.ChildID = chi.ChildID
							JOIN tblFamily fam (NOLOCK)
								ON chi.FamilyID = fam.FamilyID
							LEFT JOIN tblProgram prog (NOLOCK)
								ON dbd.ProgramID = prog.ProgramID
					WHERE	--Insert records if monthly summary is chosen
							(@optPaymentDetailSummary = 4
								--or rate type is monthly, regardless of summary choice
								OR rt.RateTypeCode = @constRateTypeCode_Monthly)
							--Also determine which days to exclude
							--For hourly and daily rate types:
							AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
									--Exclude days with no care
									AND dbd.Hours > 0
								--For weekly rate type:
								OR rt.RateTypeCode = @constRateTypeCode_Weekly
									--Exclude weekends when based on scheduled care
									AND (@optProrationMethod = 1
											AND dbd.DayOfWeek > 1
											AND dbd.DayOfWeek < 7
										OR @optProrationMethod = 2)
								--Exclude no days for monthly rate type
								--This line is included to ensure that
								--monthly rate types are not inadvertently excluded
								OR rt.RateTypeCode = @constRateTypeCode_Monthly)
							--Most family fee calculation is handled separately,
							--except for private/full fee families
							AND (@criOption <> 3
								OR prog.FamilyFeeSchedule = 1)
							--Make sure day is marked to be paid
							AND dbd.PayChargeForDay = 1) mon
					--Determine actual number of days attended during month
					JOIN	(SELECT		dbd.ScheduleID,
										CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
										dbd.ProgramID,
										dbd.PaymentTypeID,
										dbd.RateTypeID,
										dbd.CareTimeID,
										CASE
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
												THEN NULL
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily) AND @criOption = 3 AND sched.SiblingDiscount = 1
												THEN dbd.Rate * (1.00 - @optSiblingDiscountPercentage)
											ELSE dbd.Rate
										END AS Rate,
										CASE
											WHEN sched.StartDate > dbd.MonthStart
												THEN sched.StartDate
											ELSE dbd.MonthStart
										END AS MonthStart,
										CASE
											WHEN sched.StopDate < dbd.MonthStop
												THEN sched.StopDate
											ELSE dbd.MonthStop
										END AS MonthStop,
										COUNT(DISTINCT dbd.CalendarDate) AS ActualDaysInMonth
							FROM		#tmpDayByDay dbd
										JOIN tlkpRateType rt (NOLOCK)
											ON dbd.RateTypeID = rt.RateTypeID
										JOIN #tmpScheduleCopy sched
											ON dbd.ScheduleID = sched.ScheduleID
												AND dbd.ExtendedSchedule = sched.ExtendedSchedule
										LEFT JOIN tblProgram prog (NOLOCK)
											ON dbd.ProgramID = prog.ProgramID
							WHERE		--Insert records if monthly summary is chosen
										(@optPaymentDetailSummary = 4
											--or rate type is monthly, regardless of summary choice
											OR rt.RateTypeCode = @constRateTypeCode_Monthly)
										--Also determine which days to exclude
										--For hourly and daily rate types:
										AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
												--Exclude days with no care
												AND dbd.Hours > 0
											--For weekly rate type:
											OR rt.RateTypeCode = @constRateTypeCode_Weekly
												--Exclude weekends when based on scheduled care
												AND (@optProrationMethod = 1
														AND dbd.DayOfWeek > 1
														AND dbd.DayOfWeek < 7
													OR @optProrationMethod = 2)
											--Exclude no days for monthly rate type
											--This line is included to ensure that
											--monthly rate types are not inadvertently excluded
											OR rt.RateTypeCode = @constRateTypeCode_Monthly)
										--Most family fee calculation is handled separately,
										--except for private/full fee families
										AND (@criOption <> 3
											OR prog.FamilyFeeSchedule = 1)
										--Make sure day is marked to be paid
										AND dbd.PayChargeForDay = 1
							GROUP BY	dbd.ScheduleID,
										CONVERT(TINYINT, dbd.ExtendedSchedule),
										dbd.ProgramID,
										dbd.PaymentTypeID,
										dbd.RateTypeID,
										dbd.CareTimeID,
										CASE
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
												THEN NULL
											WHEN rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily) AND @criOption = 3 AND sched.SiblingDiscount = 1
												THEN dbd.Rate * (1.00 - @optSiblingDiscountPercentage)
											ELSE dbd.Rate
										END,
										CASE
											WHEN sched.StartDate > dbd.MonthStart
												THEN sched.StartDate
											ELSE dbd.MonthStart
										END,
										CASE
											WHEN sched.StopDate < dbd.MonthStop
												THEN sched.StopDate
											ELSE dbd.MonthStop
										END) rates
						ON mon.ScheduleID = rates.ScheduleID
							AND mon.ExtendedSchedule = rates.ExtendedSchedule
							AND mon.ProgramID = rates.ProgramID
							AND mon.PaymentTypeID = rates.PaymentTypeID
							AND mon.RateTypeID = rates.RateTypeID
							AND mon.CareTimeID = rates.CareTimeID
							AND mon.MonthStart = rates.MonthStart
							AND mon.MonthStop = rates.MonthStop
		WHERE		mon.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
						AND ISNULL(mon.Rate, 0) = ISNULL(rates.Rate, 0)
					OR mon.RateTypeCode IN (@constRateTypeCode_Weekly, @constRateTypeCode_Monthly)
		GROUP BY	mon.FamilyID,
					mon.ChildID,
					mon.ProgramID,
					mon.ScheduleID,
					mon.ScheduleDetailID,
					mon.ProviderID,
					mon.ExtendedSchedule,
					mon.MonthStart,
					mon.MonthStop,
					mon.Evening,
					mon.Weekend,
					mon.DaysInMonth,
					mon.PaymentTypeID,
					mon.RateTypeID,
					mon.RateTypeCode,
					mon.CareTimeID,
					mon.Rate,
					rates.ActualDaysInMonth
		OPTION		(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		IF @optDeductFamilyFees = 1
			BEGIN
				SELECT	@procDebugMessage = 'Insertion of family fee results to data table'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Family fee
				--Daily summary
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total,
					Breakfast,
					Lunch,
					Snack,
					Dinner)
				SELECT	DISTINCT
						chi.FamilyID,
						chi.ChildID,
						ff.ProgramID,
						sched.ProviderID,
						sched.ExtendedSchedule,
						ff.CalendarDate,
						ff.CalendarDate,
						@constPaymentTypeID_FamilyFee,
						@constRateTypeID_Daily,
						ff.CareTimeID,
						-ff.Rate,
						1,
						ROUND(-ff.Rate, 2),
						dbd.Breakfast,
						dbd.Lunch,
						dbd.Snack,
						dbd.Dinner
				FROM	#tmpDayByDay dbd
						JOIN #tmpScheduleCopy sched
							ON dbd.ScheduleID = sched.ScheduleID
								AND dbd.ExtendedSchedule = sched.ExtendedSchedule
						JOIN #tmpFamilyFee ff
							ON dbd.CalendarDate = ff.CalendarDate
								AND sched.ChildID = ff.ChildID
						JOIN tblChild chi (NOLOCK)
							ON ff.ChildID = chi.ChildID
						JOIN tlkpRateType rt (NOLOCK)
							ON dbd.RateTypeID = rt.RateTypeID
				WHERE	ff.Rate > 0
						AND (@optPaymentDetailSummary = 1
								AND (rt.RateTypeCode = @constRateTypeCode_Hourly
									OR rt.RateTypeCode = @constRateTypeCode_Daily)
							OR @optPaymentDetailSummary = 2
								AND rt.RateTypeCode <> @constRateTypeCode_Monthly)
						AND sched.PrimaryProvider = 1
				OPTION	(KEEP PLAN)

				--Weekly summary
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total,
					Breakfast,
					Lunch,
					Snack,
					Dinner)
				SELECT		wk.FamilyID,
							wk.ChildID,
							wk.ProgramID,
							wk.ProviderID,
							wk.ExtendedSchedule,
							wk.WeekStart,
							wk.WeekStop,
							wk.PaymentTypeID,
							wk.RateTypeID,
							wk.CareTimeID,
							wk.Rate,
							SUM(1),
							ROUND(SUM(wk.Rate), 2),
							MAX(CONVERT(TINYINT, wk.Breakfast)),
							MAX(CONVERT(TINYINT, wk.Lunch)),
							MAX(CONVERT(TINYINT, wk.Snack)),
							MAX(CONVERT(TINYINT, wk.Dinner))
				FROM		--Use schedule start date as start date of record if later than
							--the week start date, and use schedule stop date if earlier
							--than the week stop date
							(SELECT	DISTINCT
									chi.FamilyID,
									chi.ChildID,
									ff.ProgramID,
									sched.ProviderID,
									CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
									ff.CalendarDate,
									CASE
										WHEN sched.StartDate > dbd.WeekStart
											THEN sched.StartDate
										ELSE dbd.WeekStart
									END AS WeekStart,
									CASE
										WHEN sched.StopDate < dbd.WeekStop
											THEN sched.StopDate
										ELSE dbd.WeekStop
									END AS WeekStop,
									@constPaymentTypeID_FamilyFee AS PaymentTypeID,
									@constRateTypeID_Daily AS RateTypeID,
									ff.CareTimeID,
									-ff.Rate AS Rate,
									dbd.Breakfast,
									dbd.Lunch,
									dbd.Snack,
									dbd.Dinner
							FROM	#tmpDayByDay dbd
									JOIN tlkpRateType rt (NOLOCK)
										ON dbd.RateTypeID = rt.RateTypeID
									JOIN #tmpScheduleCopy sched
										ON dbd.ScheduleID = sched.ScheduleID
											AND dbd.ExtendedSchedule = sched.ExtendedSchedule
									JOIN #tmpFamilyFee ff
										ON dbd.CalendarDate = ff.CalendarDate
											AND sched.ChildID = ff.ChildID
									JOIN tblChild chi (NOLOCK)
										ON ff.ChildID = chi.ChildID
							WHERE	ff.Rate > 0
									AND (@optPaymentDetailSummary = 1
											AND rt.RateTypeCode = @constRateTypeCode_Weekly
											AND NOT EXISTS	(SELECT	dbd.*
															FROM	#tmpDayByDay dbd
																	JOIN tlkpRateType rt (NOLOCK)
																		ON dbd.RateTypeID = rt.RateTypeID
															WHERE	rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily))
										OR @optPaymentDetailSummary = 3
											AND rt.RateTypeCode <> @constRateTypeCode_Monthly)
									AND sched.PrimaryProvider = 1) wk
				GROUP BY	wk.FamilyID,
							wk.ChildID,
							wk.ProgramID,
							wk.ProviderID,
							wk.ExtendedSchedule,
							wk.WeekStart,
							wk.WeekStop,
							wk.PaymentTypeID,
							wk.RateTypeID,
							wk.CareTimeID,
							wk.Rate
				OPTION		(KEEP PLAN)

				--Monthly summary
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total,
					Breakfast,
					Lunch,
					Snack,
					Dinner)
				SELECT		mon.FamilyID,
							mon.ChildID,
							mon.ProgramID,
							mon.ProviderID,
							mon.ExtendedSchedule,
							mon.MonthStart,
							mon.MonthStop,
							mon.PaymentTypeID,
							mon.RateTypeID,
							mon.CareTimeID,
							mon.Rate,
							SUM(1),
							ROUND(SUM(mon.Rate), 2),
							MAX(CONVERT(TINYINT, mon.Breakfast)),
							MAX(CONVERT(TINYINT, mon.Lunch)),
							MAX(CONVERT(TINYINT, mon.Snack)),
							MAX(CONVERT(TINYINT, mon.Dinner))
				FROM		--Use schedule start date as start date of record if later than
							--the month start date, and use schedule stop date if earlier
							--than the month stop date
							(SELECT	DISTINCT
									chi.FamilyID,
									chi.ChildID,
									ff.ProgramID,
									sched.ProviderID,
									CONVERT(TINYINT, dbd.ExtendedSchedule) AS ExtendedSchedule,
									ff.CalendarDate,
									CASE
										WHEN sched.StartDate > dbd.MonthStart
											THEN sched.StartDate
										ELSE dbd.MonthStart
									END AS MonthStart,
									CASE
										WHEN sched.StopDate < dbd.MonthStop
											THEN sched.StopDate
										ELSE dbd.MonthStop
									END AS MonthStop,
									@constPaymentTypeID_FamilyFee AS PaymentTypeID,
									@constRateTypeID_Daily AS RateTypeID,
									ff.CareTimeID,
									-ff.Rate AS Rate,
									dbd.Breakfast,
									dbd.Lunch,
									dbd.Snack,
									dbd.Dinner
							FROM	#tmpDayByDay dbd
									JOIN tlkpRateType rt (NOLOCK)
										ON dbd.RateTypeID = rt.RateTypeID
									JOIN #tmpScheduleCopy sched
										ON dbd.ScheduleID = sched.ScheduleID
											AND dbd.ExtendedSchedule = sched.ExtendedSchedule
									JOIN #tmpFamilyFee ff
										ON dbd.CalendarDate = ff.CalendarDate
											AND sched.ChildID = ff.ChildID
									JOIN tblChild chi (NOLOCK)
										ON ff.ChildID = chi.ChildID
							WHERE	ff.Rate > 0
									AND (@optPaymentDetailSummary = 4
										OR rt.RateTypeCode = @constRateTypeCode_Monthly
											AND NOT EXISTS	(SELECT	dbd.*
															FROM	#tmpDayByDay dbd
																	JOIN tlkpRateType rt (NOLOCK)
																		ON dbd.RateTypeID = rt.RateTypeID
															WHERE	rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily, @constRateTypeCode_Weekly)))
									AND sched.PrimaryProvider = 1) mon
				GROUP BY	mon.FamilyID,
							mon.ChildID,
							mon.ProgramID,
							mon.ProviderID,
							mon.ExtendedSchedule,
							mon.MonthStart,
							mon.MonthStop,
							mon.PaymentTypeID,
							mon.RateTypeID,
							mon.CareTimeID,
							mon.Rate
				OPTION		(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		--Fixed fee
		--Determined differently for provider payment vs. family fee
		SELECT	@procDebugMessage = 'Insertion of fixed fees to data table'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		IF @optProgramSource = 1 --Child level
			BEGIN
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total)
				SELECT	DISTINCT
						chi.FamilyID,
						chi.ChildID,
						ISNULL(fee.ProgramID,cp.ProgramID),
						sched.ScheduleID,
						sched.ProviderID,
						sched.ExtendedSchedule,
						--If fee is not Recurrence, use the fee date entered on the schedule form
						--If fee is Recurrence, use the anniversary date of the original fee date
						CASE
							WHEN fee.Recurrence = 0
								THEN fee.FeeDate
							WHEN fee.Recurrence = 1
								THEN DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
							WHEN fee.Recurrence = 2
								THEN DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
							WHEN fee.Recurrence = 3
								THEN cal.CalendarDate
						END,
						CASE
							WHEN fee.Recurrence = 0
								THEN fee.FeeDate
							WHEN fee.Recurrence = 1
								THEN DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
							WHEN fee.Recurrence = 2
								THEN DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
							WHEN fee.Recurrence = 3
								THEN cal.CalendarDate
						END,
						@constPaymentTypeID_FixedFee,
						CASE fee.Recurrence
							WHEN 3
								THEN @constRateTypeID_Weekly
							ELSE @constRateTypeID_Monthly
						END,
						@constCareTimeID_FullTime,
						fee.FeeAmount,
						1,
						ROUND(fee.FeeAmount, 2)
				FROM	tblScheduleFee fee (NOLOCK)
						JOIN #tmpScheduleCopy sched (NOLOCK)
							ON fee.ScheduleID = sched.ScheduleID
						--We only want one program
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
						JOIN tlnkChildProgram cp (NOLOCK)
							ON chi.ChildID = cp.ChildID													
						JOIN #tmpCalendar cal
							ON sched.StartDate <= cal.CalendarDate
								AND sched.StopDate >= cal.CalendarDate
				WHERE	fee.FeeDate <= cal.CalendarDate
						--Current Fee
						AND (fee.Recurrence = 0
								AND fee.FeeDate BETWEEN sched.StartDate AND sched.StopDate
								AND (cp.StartDate <= fee.FeeDate
									OR cp.StartDate IS NULL)
								AND (cp.StopDate >= fee.FeeDate
									OR cp.StopDate IS NULL)			
							--Annual Fee					
							OR fee.Recurrence = 1
								AND (cp.StartDate <= DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
									OR cp.StartDate IS NULL)
								AND (cp.StopDate >= DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
									OR cp.StopDate IS NULL)
							--Monthly Fee
							OR fee.Recurrence = 2
								AND (cp.StartDate <= DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
										OR cp.StartDate IS NULL)
								AND (cp.StopDate >= DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
										OR cp.StopDate IS NULL)									
							OR fee.Recurrence = 3
								AND DATEPART(WEEKDAY,fee.FeeDate) = cal.DayOfWeek
								AND (cp.StartDate <= cal.CalendarDate
									OR cp.StartDate IS NULL)
								AND (cp.StopDate >= cal.CalendarDate
									OR cp.StopDate IS NULL))			
						--Add to time sheet/projection calculation
						AND (@criOption <> 3
								--If the fee applies to provider payment
								AND fee.AppliesTo = 1
								--and the agency is paying the fee
								AND fee.PaidByParent = 0
							--Add to family fee billing
							OR @criOption = 3
								--if the fee applies to family fee
								AND fee.AppliesTo = 2
								--and the parent is paying the fee
								AND fee.PaidByParent = 1)
						AND (ISNULL(fee.ProgramID,cp.ProgramID) = @criProgramID
							OR @criProgramID = 0)
				OPTION	(KEEP PLAN)

				--Insert fixed fee error code (projection only)
				IF @criOption = 2
					INSERT	#tmpError
						(FamilyID,
						ChildID,
						ProgramID,
						ScheduleID,
						ProviderID,
						ErrorDate,
						ErrorCode,
						ErrorDesc)
					SELECT	DISTINCT
							chi.FamilyID,
							chi.ChildID,
							ISNULL(fee.ProgramID,cp.ProgramID),
							sched.ScheduleID,
							sched.ProviderID,
							sched.StartDate,
							'FEE',
							'Fixed Fee'
					FROM	tblScheduleFee fee (NOLOCK)
							JOIN #tmpScheduleCopy sched (NOLOCK)
								ON fee.ScheduleID = sched.ScheduleID
							JOIN tblChild chi (NOLOCK)
								ON sched.ChildID = chi.ChildID
							JOIN tlnkChildProgram cp (NOLOCK)
								ON chi.ChildID = cp.ChildID
							JOIN #tmpCalendar cal
								ON sched.StartDate <= cal.CalendarDate
								AND sched.StopDate >= cal.CalendarDate
					WHERE	fee.FeeDate <= cal.CalendarDate
							--Current Fee
							AND (fee.Recurrence = 0
									AND fee.FeeDate BETWEEN sched.StartDate AND sched.StopDate
									AND (cp.StartDate <= fee.FeeDate
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= fee.FeeDate
										OR cp.StopDate IS NULL)								
								--Annual Fee
								OR fee.Recurrence = 1
									AND (cp.StartDate <= DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
										OR cp.StartDate IS NULL)
									AND (cp.StopDate >= DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
										OR cp.StopDate IS NULL)
								--Monthly Fee
								OR fee.Recurrence = 2
									AND (cp.StartDate <= DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
											OR cp.StartDate IS NULL)
									AND (cp.StopDate >= DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
											OR cp.StopDate IS NULL)									
								--Weekly Fee
							OR fee.Recurrence = 3
								AND DATEPART(WEEKDAY,fee.FeeDate) = cal.DayOfWeek
								AND (cp.StartDate <= cal.CalendarDate
									OR cp.StartDate IS NULL)
								AND (cp.StopDate >= cal.CalendarDate
									OR cp.StopDate IS NULL))
								--Add to time sheet/projection calculation
								--Only include if the agency is paying the fee
								AND fee.PaidByParent = 0
								--and the fee applies to provider payment
								AND fee.AppliesTo = 1
								AND (ISNULL(fee.ProgramID,cp.ProgramID) = @criProgramID
									OR @criProgramID = 0)
				OPTION	(KEEP PLAN)					
			END

		IF @optProgramSource = 2 --Schedule detail level
			BEGIN
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total)
				SELECT	DISTINCT
						chi.FamilyID,
						chi.ChildID,
						ISNULL(fee.ProgramID,sp.ProgramID),
						sched.ScheduleID,
						sched.ProviderID,
						sched.ExtendedSchedule,
						--If fee is not Recurrence, use the fee date entered on the schedule form
						--If fee is Recurrence, use the anniversary date of the original fee date
						CASE
							WHEN fee.Recurrence = 0
								THEN fee.FeeDate
							WHEN fee.Recurrence = 1
								THEN DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
							WHEN fee.Recurrence = 2
								THEN DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
							WHEN fee.Recurrence = 3
								THEN cal.CalendarDate
						END,
						CASE
							WHEN fee.Recurrence = 0
								THEN fee.FeeDate
							WHEN fee.Recurrence = 1
								THEN DATEADD(YEAR, DATEPART(YEAR, sched.StartDate) - DATEPART(YEAR, fee.FeeDate), fee.FeeDate)
							WHEN fee.Recurrence = 2
								THEN DATEADD(MONTH, DATEDIFF(MONTH, fee.FeeDate, @procStartDate), fee.FeeDate)
							WHEN fee.Recurrence = 3
								THEN cal.CalendarDate
						END,
						@constPaymentTypeID_FixedFee,
						CASE fee.Recurrence
							WHEN 3
								THEN @constRateTypeID_Weekly
							ELSE @constRateTypeID_Monthly
						END,
						@constCareTimeID_FullTime,
						fee.FeeAmount,
						1,
						ROUND(fee.FeeAmount, 2)
				FROM	tblScheduleFee fee (NOLOCK)
						JOIN #tmpScheduleCopy sched (NOLOCK)
							ON fee.ScheduleID = sched.ScheduleID
						--We only want one program
						JOIN #tmpScheduleProgram sp (NOLOCK)
							ON fee.ScheduleID = sp.ScheduleID														
						JOIN tblChild chi (NOLOCK)
							ON sched.ChildID = chi.ChildID
						JOIN #tmpCalendar cal
							ON sched.StartDate <= cal.CalendarDate
							AND sched.StopDate >= cal.CalendarDate
				WHERE	fee.FeeDate <= cal.CalendarDate
						AND ((fee.Recurrence = 0
								AND fee.FeeDate BETWEEN sched.StartDate AND sched.StopDate)
							OR (fee.Recurrence = 1
								AND DATEPART(DAY, fee.FeeDate) BETWEEN DATEPART(DAY, sched.StartDate) AND DATEPART(DAY, sched.StopDate)
								AND DATEPART(MONTH, fee.FeeDate) BETWEEN DATEPART(MONTH, sched.StartDate) AND DATEPART(MONTH, sched.StopDate))
							OR (fee.Recurrence = 2)
							OR (fee.Recurrence = 3
								AND DATEPART(WEEKDAY,fee.FeeDate) = cal.DayOfWeek))
						--Add to time sheet/projection calculation
						AND (@criOption <> 3
								--if the fee applies to provider payment
								AND fee.AppliesTo = 1
								--and the agency is paying the fee
								AND fee.PaidByParent = 0
							--Add to family fee billing
							OR @criOption = 3
								--if the fee applies to family fee
								AND fee.AppliesTo = 2
								--and the parent is paying the fee
								AND fee.PaidByParent = 1)
						AND (ISNULL(fee.ProgramID,sp.ProgramID) = @criProgramID
							OR @criProgramID = 0)
				OPTION	(KEEP PLAN)

				--Insert fixed fee error code (projection only)
				IF @criOption = 2
					INSERT	#tmpError
						(FamilyID,
						ChildID,
						ProgramID,
						ScheduleID,
						ProviderID,
						ErrorDate,
						ErrorCode,
						ErrorDesc)
					SELECT	DISTINCT
							chi.FamilyID,
							chi.ChildID,
							ISNULL(fee.ProgramID,sp.ProgramID),
							sched.ScheduleID,
							sched.ProviderID,
							sched.StartDate,
							'FEE',
							'Fixed Fee'
					FROM	tblScheduleFee fee (NOLOCK)
							JOIN #tmpScheduleCopy sched (NOLOCK)
								ON fee.ScheduleID = sched.ScheduleID
							--We only want one program
							JOIN #tmpScheduleProgram sp (NOLOCK)
								ON fee.ScheduleID = sp.ScheduleID							
							JOIN tblChild chi (NOLOCK)
								ON sched.ChildID = chi.ChildID
							JOIN #tmpCalendar cal
								ON sched.StartDate <= cal.CalendarDate
								AND sched.StopDate >= cal.CalendarDate
					WHERE	fee.FeeDate <= cal.CalendarDate
							AND ((fee.Recurrence = 0
									AND fee.FeeDate BETWEEN sched.StartDate AND sched.StopDate)
								OR (fee.Recurrence = 1
									AND DATEPART(DAY, fee.FeeDate) BETWEEN DATEPART(DAY, sched.StartDate) AND DATEPART(DAY, sched.StopDate)
									AND DATEPART(MONTH, fee.FeeDate) BETWEEN DATEPART(MONTH, sched.StartDate) AND DATEPART(MONTH, sched.StopDate))
								OR (fee.Recurrence = 2)
								OR (fee.Recurrence = 3
									AND DATEPART(WEEKDAY,fee.FeeDate) = cal.DayOfWeek))
							--Only include if the agency is paying the fee
							AND fee.PaidByParent = 0
							--and the fee applies to provider payment
							AND fee.AppliesTo = 1
							AND (ISNULL(fee.ProgramID,sp.ProgramID) = @criProgramID
								OR @criProgramID = 0)
					OPTION	(KEEP PLAN)
				END
				
		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		--Family fee and Family Fee Adjustments
		IF @criOption = 3 OR @criOption = 4
			BEGIN
				SELECT	@procDebugMessage = 'Insertion of family fee results to data table'

				IF @criDebug = 1
					EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

				--Family fees are calculated on a daily basis only; however, billing
				--of private children could be done on a weekly or monthly basis -
				--two INSERTs will be needed, one for hourly, daily, or weekly rate
				--types, one for monthly (to total the billing for the month)

				--Hourly/daily/weekly
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ScheduleDetailID,
					ProviderID,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total)
				SELECT	chi.FamilyID,
						chi.ChildID,
						ff.ProgramID,
						ff.ScheduleID,
						ff.ScheduleDetailID,
						ff.ProviderID,
						ff.CalendarDate,
						ff.CalendarDate,
						@constPaymentTypeID_FamilyFee,
						ff.RateTypeID,
						ff.CareTimeID,
						ff.Rate,
						CASE
							WHEN rt.RateTypeCode = @constRateTypeCode_Hourly
								THEN ff.Hours
							WHEN rt.RateTypeCode = @constRateTypeCode_Daily
								THEN 1
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
								THEN .2
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
								THEN ROUND((1 / ff.DaysPerWeek), 2)
						END,
						CASE
							WHEN rt.RateTypeCode = @constRateTypeCode_Hourly
								THEN ff.Hours * ROUND(ff.Rate, 2)
							WHEN rt.RateTypeCode = @constRateTypeCode_Daily
								THEN ROUND(ff.Rate, 2)
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
								THEN .2 * ROUND(ff.Rate, 2)
							WHEN rt.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
								THEN ROUND((1 / ff.DaysPerWeek), 2) * ROUND(ff.Rate, 2)
						END
				FROM	#tmpFamilyFee ff
						JOIN tblChild chi (NOLOCK)
							ON ff.ChildID = chi.ChildID
						JOIN tblFamily fam (NOLOCK)
							ON chi.FamilyID = fam.FamilyID
						JOIN tlkpRateType rt (NOLOCK)
							ON ff.RateTypeID = rt.RateTypeID
						LEFT JOIN tblProgram prog (NOLOCK)
							ON ff.ProgramID = prog.ProgramID
				WHERE	ff.Rate > 0
						AND (rt.RateTypeCode IN (@constRateTypeCode_Hourly, @constRateTypeCode_Daily)
							OR rt.RateTypeCode = @constRateTypeCode_Weekly
								AND (@optProrationMethod = 1
										AND ff.DayOfWeek NOT IN (1, 7)
									OR @optProrationMethod = 2))
						--Exclude private/full fee families
						AND prog.FamilyFeeSchedule <> 1
				OPTION	(KEEP PLAN)

				--Monthly
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ScheduleDetailID,
					ProviderID,
					StartDate,
					StopDate,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total)
				SELECT		mon.FamilyID,
							mon.ChildID,
							mon.ProgramID,
							mon.ScheduleID,
							mon.ScheduleDetailID,
							mon.ProviderID,
							mon.MonthStart,
							mon.MonthStop,
							mon.PaymentTypeID,
							mon.RateTypeID,
							mon.CareTimeID,
							mon.Rate,
							--Units
							CASE
								WHEN mon.RateTypeCode = @constRateTypeCode_Hourly
									THEN CONVERT(NUMERIC (5, 2), SUM(mon.Hours))
								WHEN mon.RateTypeCode = @constRateTypeCode_Daily
									THEN CONVERT(NUMERIC (5, 2), SUM(1))
								WHEN mon.RateTypeCode = @constRateTypeCode_Weekly
									THEN CONVERT(NUMERIC (5, 2), SUM(.2))
								WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
									THEN CONVERT(NUMERIC (5, 2), SUM(1) / mon.DaysInWeek)
								WHEN mon.RateTypeCode = @constRateTypeCode_Monthly
									--Each day in the month counts for a fraction of one monthly unit.
									--This fraction is determined by dividing 1 by the number of days
									--in the month.  Whether a day counts toward the total number of units
									--is determined by whether the schedule was in effect on that day,
									--not whether case was scheduled for that specific day.  For example,
									--if a schedule runs from November 1st through November 20th, the total
									--units for a monthly schedule would be equal to 20/30, or approximately
									--0.6667, even if care is only scheduled on Mondays and Wednesdays
									THEN CONVERT(NUMERIC (5, 2), SUM(1) / mon.DaysInMonth)
							END AS Units,
							--Total
							CASE
								WHEN mon.RateTypeCode = @constRateTypeCode_Hourly
									THEN SUM(mon.Hours * mon.Rate)
								WHEN mon.RateTypeCode = @constRateTypeCode_Daily
									THEN SUM(mon.Rate)
								WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 1
									THEN SUM(.2 * mon.Rate)
								WHEN mon.RateTypeCode = @constRateTypeCode_Weekly AND @optProrationMethod = 2
									THEN ROUND(SUM(1) / mon.DaysInWeek, 2) * mon.Rate
								WHEN mon.RateTypeCode = @constRateTypeCode_Monthly
									THEN ROUND(SUM(1) / mon.DaysInMonth, 2) * mon.Rate
							END AS Total
				FROM		--Use schedule start date as start date of record if later than the
							--month start date, and use schedule stop date if earlier than the
							--month stop date
							(SELECT	chi.FamilyID,
									chi.ChildID,
									ff.ProgramID,
									ff.ScheduleID,
									ff.ScheduleDetailID,
									ff.ProviderID,
									CASE
										WHEN ff.StartDate > ff.MonthStart
											THEN ff.StartDate
										ELSE ff.MonthStart
									END AS MonthStart,
									CASE
										WHEN ff.StopDate < ff.MonthStop
											THEN ff.StopDate
										ELSE ff.MonthStop
									END AS MonthStop,
									CONVERT(NUMERIC (4, 2), ff.DaysPerWeek) AS DaysInWeek,
									CASE
										WHEN @optProrationMethod = 1
											THEN CONVERT(NUMERIC (4, 2), DATEPART(DAY, ff.MonthStop))
										WHEN @optProrationMethod = 2
											THEN CONVERT(NUMERIC (4, 2), ff.DaysPerMonth)
									END AS DaysInMonth,
									@constPaymentTypeID_FamilyFee AS PaymentTypeID,
									ff.RateTypeID,
									rt.RateTypeCode,
									ff.CareTimeID,
									ff.Rate,
									ff.Hours
							FROM	#tmpFamilyFee ff
									JOIN tblChild chi (NOLOCK)
										ON ff.ChildID = chi.ChildID
									JOIN tblFamily fam (NOLOCK)
										ON chi.FamilyID = fam.FamilyID
									JOIN tlkpRateType rt (NOLOCK)
										ON ff.RateTypeID = rt.RateTypeID
									LEFT JOIN tblProgram prog (NOLOCK)
										ON ff.ProgramID = prog.ProgramID
							WHERE	rt.RateTypeCode = @constRateTypeCode_Monthly
									--Exclude private/full fee families
									AND prog.FamilyFeeSchedule <> 1) mon
				GROUP BY	mon.FamilyID,
							mon.ChildID,
							mon.ProgramID,
							mon.ScheduleID,
							mon.ScheduleDetailID,
							mon.ProviderID,
							mon.MonthStart,
							mon.MonthStop,
							mon.DaysInWeek,
							mon.DaysInMonth,
							mon.PaymentTypeID,
							mon.RateTypeID,
							mon.RateTypeCode,
							mon.CareTimeID,
							mon.Rate
				OPTION		(KEEP PLAN)

				IF @criDebug = 1
					EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
			END

		/* Validate payment total against monthly RMR */
		SELECT	@procDebugMessage = 'Validation against monthly RMR'
		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT
	
		IF @optPreventPaymentsInExcessOfMonthlyRMR = 1
			BEGIN
				--Set child age as of the beginning of the calculation period
				UPDATE	res
				SET		ChildAge =	CASE
										WHEN DATEPART(MONTH, c.BirthDate) > DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) > DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) - 1 + ((DATEDIFF(MONTH, c.BirthDate, @procStartDate) - 1) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) > DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) = DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) - 1 + (DATEDIFF(MONTH, c.BirthDate, @procStartDate) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) > DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) < DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) - 1 + (DATEDIFF(MONTH, c.BirthDate, @procStartDate) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) = DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) > DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) - 1 + ((DATEDIFF(MONTH, c.BirthDate, @procStartDate) - 1) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) = DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) = DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate))
										WHEN DATEPART(MONTH, c.BirthDate) = DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) < DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) + (DATEDIFF(MONTH, c.BirthDate, @procStartDate) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) < DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) > DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) + ((DATEDIFF(MONTH, c.BirthDate, @procStartDate) - 1) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) < DATEPART(MONTH, @procStartDate) AND DATEPART(DAY, c.BirthDate) = DATEPART(DAY, @procStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @procStartDate) + (DATEDIFF(MONTH, c.BirthDate, @criStartDate) % 12) / 12.00)
										WHEN DATEPART(MONTH, c.BirthDate) < DATEPART(MONTH, @criStartDate) AND DATEPART(DAY, c.BirthDate) < DATEPART(DAY, @criStartDate)
											THEN CONVERT(NUMERIC (5, 2), DATEDIFF(YEAR, c.BirthDate, @criStartDate) + (DATEDIFF(MONTH, c.BirthDate, @criStartDate) % 12) / 12.00)
									END
				FROM	#tmpResult res
						JOIN tblChild c (NOLOCK)
							ON res.ChildID = c.ChildID
				WHERE	res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				--Set total payment amount
				UPDATE	res
				SET		MonthlyTotal = sub.Total
				FROM	#tmpResult res
						JOIN	(SELECT		ChildID,
											ProviderID,
											CASE
												WHEN Evening = 1 OR Weekend = 1
													THEN 1
												ELSE 0
											END AS EveningWeekend,
											SUM(Total) AS Total
								FROM		#tmpResult (NOLOCK)
								WHERE		StartDate <= @procStopDate
											AND StopDate >= @procStartDate
								GROUP BY	ChildID,
											ProviderID,
											CASE
												WHEN Evening = 1 OR Weekend = 1
													THEN 1
												ELSE 0
											END) sub
							ON res.ChildID = sub.ChildID
								AND res.ProviderID = sub.ProviderID
								AND	(CASE
										WHEN res.Evening = 1 OR res.Weekend = 1
											THEN 1
										ELSE 0
									END) = sub.EveningWeekend
				WHERE	res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				--Set RMR multiplier
				UPDATE	res
				SET		RMRDescriptionID = CASE
												WHEN pg.UseProviderRMR = 1 
													THEN p.RMRDescriptionID
												ELSE pg.RMRDescriptionID
											END
				FROM	#tmpResult res
						JOIN tblProvider p (NOLOCK)
							ON res.ProviderID = p.ProviderID
						JOIN tblProgram pg (NOLOCK)
							ON res.ProgramID = pg.ProgramID
				OPTION	(KEEP PLAN)
				
				UPDATE	res
				SET		RMRMultiplierEffectiveDate = sub.EffectiveDate
				FROM	#tmpResult res
						JOIN	(SELECT		RMRDescriptionID,
											MAX(EffectiveDate) AS EffectiveDate
								FROM		tlkpRMRMultiplier (NOLOCK)
								WHERE		EffectiveDate <= @procStartDate
								GROUP BY	RMRDescriptionID) sub
							ON res.RMRDescriptionID = sub.RMRDescriptionID
				OPTION	(KEEP PLAN)

				UPDATE	res
				SET		RMRMultiplier = mult.Multiplier
				FROM	#tmpResult res
						JOIN tblChild chi (NOLOCK)
							ON res.ChildID = chi.ChildID
						JOIN tblSchedule s (NOLOCK)
							ON res.ScheduleID = s.ScheduleID,
						tlkpRMRMultiplier mult (NOLOCK)
				WHERE	mult.EffectiveDate = res.RMRMultiplierEffectiveDate
						AND mult.RMRDescriptionID = res.RMRDescriptionID
						AND mult.Multiplier >= res.RMRMultiplier
						AND s.SpecialNeedsRMRMultiplier = 1
						AND dbo.ChildHasSpecialNeed(res.ChildID, NULL, @procStartDate, @procStartDate) = 1
						AND mult.RMRMultiplierCode = '01'
						AND res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)
				
				UPDATE	res
				SET		RMRMultiplier = mult.Multiplier
				FROM	#tmpResult res,
						tlkpRMRMultiplier mult (NOLOCK)
				WHERE	mult.EffectiveDate = res.RMRMultiplierEffectiveDate
						AND mult.RMRDescriptionID = res.RMRDescriptionID
						AND mult.Multiplier >= res.RMRMultiplier
						AND res.Weekend = 1
						AND mult.RMRMultiplierCode = '02'
				OPTION	(KEEP PLAN)

				UPDATE	res
				SET		RMRMultiplier = mult.Multiplier
				FROM	#tmpResult res,
						tlkpRMRMultiplier mult (NOLOCK)
				WHERE	mult.EffectiveDate = res.RMRMultiplierEffectiveDate
						AND mult.RMRDescriptionID = res.RMRDescriptionID
						AND mult.Multiplier >= res.RMRMultiplier
						AND res.Evening = 1
						AND mult.RMRMultiplierCode = '03'
						AND res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				UPDATE	res
				SET		RMRMultiplier = mult.Multiplier
				FROM	#tmpResult res
						JOIN tblChild chi (NOLOCK)
							ON res.ChildID = chi.ChildID
						JOIN tblSchedule s (NOLOCK)
							ON res.ScheduleID = s.ScheduleID,
						tlkpRMRMultiplier mult (NOLOCK)
				WHERE	mult.EffectiveDate = res.RMRMultiplierEffectiveDate
						AND mult.RMRDescriptionID = res.RMRDescriptionID
						AND mult.Multiplier >= res.RMRMultiplier
						AND s.SpecialNeedsRMRMultiplier = 1
						AND dbo.ChildHasSpecialNeed(res.ChildID, '22', @procStartDate, @procStartDate) = 1
						AND mult.RMRMultiplierCode = '04'
						AND res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				UPDATE	res
				SET		RMRMultiplier = mult.Multiplier
				FROM	#tmpResult res
						JOIN tblChild chi (NOLOCK)
							ON res.ChildID = chi.ChildID
						JOIN tblSchedule s (NOLOCK)
							ON res.ScheduleID = s.ScheduleID,
						tlkpRMRMultiplier mult (NOLOCK)
				WHERE	mult.EffectiveDate = res.RMRMultiplierEffectiveDate
						AND mult.RMRDescriptionID = res.RMRDescriptionID
						AND mult.Multiplier >= res.RMRMultiplier
						AND s.SpecialNeedsRMRMultiplier = 1
						AND dbo.ChildHasSpecialNeed(res.ChildID, '24', @procStartDate, @procStartDate) = 1
						AND mult.RMRMultiplierCode = '05'
						AND res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				--Determine monthly RMR
				UPDATE	res
				SET		RMREffectiveDate = sub.EffectiveDate
				FROM	#tmpResult res
						JOIN	(SELECT		RMRDescriptionID,
											MAX(EffectiveDate) AS EffectiveDate
								FROM		tlkpRegionalMarketRate (NOLOCK)
								WHERE		EffectiveDate <= @procStartDate
								GROUP BY	RMRDescriptionID) sub
							ON res.RMRDescriptionID = sub.RMRDescriptionID
				OPTION	(KEEP PLAN)

				UPDATE	res
				SET		RMRRate = rmr.Rate * res.RMRMultiplier
				FROM	#tmpResult res
						JOIN tblProvider p (NOLOCK)
							ON res.ProviderID = p.ProviderID
						JOIN tlkpAgeBracket ab (NOLOCK)
							ON res.ChildAge >= ab.MinAge
								AND res.ChildAge < ab.MaxAge
						JOIN tlkpRegionalMarketRate rmr (NOLOCK)
							ON p.ProviderTypeID = rmr.ProviderTypeID
								AND ab.AgeBracketID = rmr.AgeBracketID
						JOIN tlkpRateType rt (NOLOCK)
							ON rmr.RateTypeID = rt.RateTypeID
						JOIN tlkpCareTime ct (NOLOCK)
							ON rmr.CareTimeID = ct.CareTimeID
				WHERE	rmr.EffectiveDate = res.RMREffectiveDate
						AND rmr.RMRDescriptionID = res.RMRDescriptionID
						AND rt.RateTypeCode = @constRateTypeCode_Monthly
						AND ct.CareTimeCode = @constCareTimeCode_FullTime
						AND res.StartDate <= @procStopDate
						AND res.StopDate >= @procStartDate
				OPTION	(KEEP PLAN)

				--Insert system generated entry for the RMR
				INSERT	#tmpResult
					(FamilyID,
					ChildID,
					ProgramID,
					ScheduleID,
					ScheduleDetailID,
					ProviderID,
					ExtendedSchedule,
					StartDate,
					StopDate,
					Evening,
					Weekend,
					PaymentTypeID,
					RateTypeID,
					CareTimeID,
					Rate,
					Units,
					Total,
					InExcessOfMonthlyRMR,
					Breakfast,
					Lunch,
					Snack,
					Dinner)
				SELECT		res.FamilyID,
							res.ChildID,
							rsub.ProgramID,
							NULL,
							NULL,
							res.ProviderID,
							MAX(CONVERT(TINYINT, res.ExtendedSchedule)),
							@procStartDate,
							@procStopDate,
							MAX(CONVERT(TINYINT, res.Evening)),
							MAX(CONVERT(TINYINT, res.Weekend)),
							@constPaymentTypeID_Regular,
							@constRateTypeID_Monthly,
							@constCareTimeID_FullTime,
							res.RMRRate,
							1,
							res.RMRRate,
							1,
							MAX(CONVERT(TINYINT, res.Breakfast)),
							MAX(CONVERT(TINYINT, res.Lunch)),
							MAX(CONVERT(TINYINT, res.Snack)),
							MAX(CONVERT(TINYINT, res.Dinner))
				FROM		#tmpResult res (NOLOCK)
							JOIN	(SELECT		r.ChildID,
												r.ProviderID,
												MIN(r.ProgramID) AS ProgramID
									FROM		#tmpResult r (NOLOCK)
												JOIN	(SELECT		ChildID,
																	ProviderID,
																	MIN(StartDate) AS StartDate
														FROM		#tmpResult (NOLOCK)
														WHERE		MonthlyTotal > RMRRate
																	AND StartDate <= @procStopDate
																	AND StopDate >= @procStartDate
																	AND ProgramID IS NOT NULL
														GROUP BY	ChildID,
																	ProviderID) sub
													ON r.ChildID = sub.ChildID
														AND r.ProviderID = sub.ProviderID
														AND r.StartDate = sub.StartDate
									WHERE		r.MonthlyTotal > r.RMRRate
									GROUP BY	r.ChildID,
												r.ProviderID) rsub
								ON res.ChildID = rsub.ChildID
									AND res.ProviderID = rsub.ProviderID
				WHERE		res.MonthlyTotal > res.RMRRate
							AND res.StartDate <= @procStopDate
							AND res.StopDate >= @procStartDate
				GROUP BY	res.FamilyID,
							res.ChildID,
							rsub.ProgramID,
							res.ProviderID,
							res.RMRRate,
							CASE
								WHEN res.Evening = 1 OR res.Weekend = 1
									THEN 1
								ELSE 0
							END
				OPTION	(KEEP PLAN)

				DELETE	#tmpResult
				WHERE	MonthlyTotal > RMRRate
						AND InExcessOfMonthlyRMR = 0
						AND StartDate <= @procStopDate
						AND StopDate >= @procStartDate
				OPTION	(KEEP PLAN)
			END

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		/* Increment procedure variables */
		SELECT	@procStartDate = DATEADD(MONTH, 1, DATEADD(DAY, -DATEPART(DAY, @procStartDate) + 1, @procStartDate))

		SELECT	@procStopDate = DATEADD(DAY, -1, DATEADD(MONTH, 1, @procStartDate))

		SELECT	@procCounter = @procCounter + 1

		IF @procStopDate > @criStopDate
			SELECT	@procStopDate = @criStopDate

		/* Update status */
		IF @criOption = 2
			UPDATE	tblProjectionStatus
			SET		CurrentRecord = @procCounter,
					CurrentDate = @procStartDate
	END

/* Delete family fee records for non-billing children */
IF @optIncludeFamilyFees = 1
	BEGIN
		/* Generate fee totals by child */
		SELECT	@procDebugMessage = 'Calculation of family fee totals by child'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		--Time sheet/provider payment
		IF @criOption = 1
			INSERT	#tmpFamilyFeeTotal
				(FamilyID,
				ChildID,
				Total)
			SELECT		FamilyID,
						ChildID,
						SUM(-Total) AS Total
			FROM		#tmpResult (NOLOCK)
			WHERE		StartDate <= @criStopDate
						AND StopDate >= @criStartDate
						AND PaymentTypeID = @constPaymentTypeID_FamilyFee
			GROUP BY	FamilyID,
						ChildID
			OPTION		(KEEP PLAN)

		--Projection
		IF @criOption = 2
			INSERT	#tmpFamilyFeeTotal
				(FamilyID,
				ChildID,
				Total)
			SELECT		FamilyID,
						ChildID,
						SUM(-Total) AS Total
			FROM		#tmpResult (NOLOCK)
			WHERE		StartDate <= @criStopDate
						AND StopDate >= @criStartDate
						AND PaymentTypeID = @constPaymentTypeID_FamilyFee
			GROUP BY	FamilyID,
						ChildID
			OPTION		(KEEP PLAN)

		--Family fee
		IF @criOption = 3  
			INSERT	#tmpFamilyFeeTotal
				(FamilyID,
				ChildID,
				Total)
			SELECT		res.FamilyID,
						res.ChildID,
						SUM(res.Total) AS Total
			FROM		#tmpResult res (NOLOCK)
						JOIN tblFamily f (NOLOCK)
							ON res.FamilyID = f.FamilyID
						LEFT JOIN tblProgram prog (NOLOCK)
							ON res.ProgramID = prog.ProgramID
			WHERE		res.StartDate <= @criStopDate
						AND res.StopDate >= @criStartDate
						AND prog.FamilyFeeSchedule <> 1
			GROUP BY	res.FamilyID,
						res.ChildID
			OPTION		(KEEP PLAN)

		--Family fee adjusment
		IF @criOption = 4
			INSERT	#tmpFamilyFeeTotal
				(FamilyID,
				ChildID,
				ServiceDate,
				Total)
			SELECT		res.FamilyID,
						res.ChildID,
						res.StartDate,
						SUM(res.Total) AS Total
			FROM		#tmpResult res (NOLOCK)
						JOIN tblFamily f (NOLOCK)
							ON res.FamilyID = f.FamilyID
						LEFT JOIN tblProgram prog (NOLOCK)
							ON res.ProgramID = prog.ProgramID
			WHERE		res.StartDate <= @criStopDate
						AND res.StopDate >= @criStartDate
						AND prog.FamilyFeeSchedule <> 1
			GROUP BY	res.FamilyID,
						res.ChildID,
						res.StartDate
			OPTION		(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		IF @criDebug = 1
			SELECT	*
			FROM	#tmpFamilyFeeTotal

		/* Determine children with highest fee for each family */
		SELECT	@procDebugMessage = 'Determination of children with highest fees by family'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		IF @criOption = 4 
			INSERT	#tmpFamilyMaxFee
				(FamilyID,
				ChildID,
				ServiceDate)
			SELECT	DISTINCT
					tot.FamilyID,
					tot.ChildID,
					tot.ServiceDate
			FROM	#tmpFamilyFeeTotal tot
					JOIN	(SELECT		FamilyID,
										ServiceDate,
										MAX(Total) AS Total
							FROM		#tmpFamilyFeeTotal
							GROUP BY	FamilyID,
										ServiceDate) maxtot
						ON tot.FamilyID = maxtot.FamilyID
							AND tot.ServiceDate = maxtot.ServiceDate
							AND tot.Total = maxtot.Total
			OPTION	(KEEP PLAN)
		ELSE		
			INSERT	#tmpFamilyMaxFee
				(FamilyID,
				ChildID)
			SELECT	DISTINCT
					tot.FamilyID,
					tot.ChildID
			FROM	#tmpFamilyFeeTotal tot
					JOIN	(SELECT		FamilyID,
										MAX(Total) AS Total
							FROM		#tmpFamilyFeeTotal
							GROUP BY	FamilyID) maxtot
						ON tot.FamilyID = maxtot.FamilyID
							AND tot.Total = maxtot.Total
			OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

		IF @criDebug = 1
			SELECT	*
			FROM	#tmpFamilyMaxFee

 		/* Delete fee data for non-billing children */
		SELECT	@procDebugMessage = 'Deletion of non-billing child fees'

		IF @criDebug = 1
			EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

		IF @criOption = 4 
			DELETE	res
			FROM	#tmpResult res (NOLOCK)
					JOIN tblFamily f (NOLOCK)
						ON res.FamilyID = f.FamilyID
					LEFT JOIN	(SELECT		maxfee.FamilyID,
											maxfee.ServiceDate,
											MAX(maxfee.ChildID) AS ChildID
								FROM		#tmpFamilyMaxFee maxfee
											JOIN tblChild chi (NOLOCK)
												ON maxfee.ChildID = chi.ChildID
											JOIN		(SELECT		maxfee.FamilyID,
																	maxfee.ServiceDate,
																	MAX(chi.Birthdate) AS BirthDate
														FROM		#tmpFamilyMaxFee maxfee
																	JOIN tblChild chi (NOLOCK)
																		ON maxfee.ChildID = chi.ChildID
														GROUP BY	maxfee.FamilyID,
																	maxfee.ServiceDate) maxdob
												ON chi.FamilyID = maxdob.FamilyID
													AND maxfee.ServiceDate = maxdob.ServiceDate
													AND chi.BirthDate = maxdob.BirthDate
								GROUP BY	maxfee.FamilyID,
											maxfee.ServiceDate) bchi
						ON res.FamilyID = bchi.FamilyID
							AND res.StartDate = bchi.ServiceDate
							AND res.ChildID = bchi.ChildID
					LEFT JOIN tblProgram prog (NOLOCK)
						ON res.ProgramID = prog.ProgramID
			WHERE	bchi.ChildID IS NULL
					AND res.StartDate <= @criStopDate
					AND res.StopDate >= @criStartDate
					AND res.PaymentTypeID = @constPaymentTypeID_FamilyFee
					AND prog.FamilyFeeSchedule <> 1
			OPTION	(KEEP PLAN)
		ELSE
			DELETE	res
			FROM	#tmpResult res (NOLOCK)
					JOIN tblFamily f (NOLOCK)
						ON res.FamilyID = f.FamilyID
					LEFT JOIN	(SELECT		maxfee.FamilyID,
											MAX(maxfee.ChildID) AS ChildID
								FROM		#tmpFamilyMaxFee maxfee
											JOIN tblChild chi (NOLOCK)
												ON maxfee.ChildID = chi.ChildID
											JOIN		(SELECT		maxfee.FamilyID,
																	MAX(chi.Birthdate) AS BirthDate
														FROM		#tmpFamilyMaxFee maxfee
																	JOIN tblChild chi (NOLOCK)
																		ON maxfee.ChildID = chi.ChildID
														GROUP BY	maxfee.FamilyID) maxdob
												ON chi.FamilyID = maxdob.FamilyID
													AND chi.BirthDate = maxdob.BirthDate
								GROUP BY	maxfee.FamilyID) bchi
						ON res.FamilyID = bchi.FamilyID
							AND res.ChildID = bchi.ChildID
					LEFT JOIN tblProgram prog (NOLOCK)
						ON res.ProgramID = prog.ProgramID
			WHERE	bchi.ChildID IS NULL
					AND res.StartDate <= @criStopDate
					AND res.StopDate >= @criStartDate
					AND res.PaymentTypeID = @constPaymentTypeID_FamilyFee
					AND prog.FamilyFeeSchedule <> 1
			OPTION	(KEEP PLAN)

		IF @criDebug = 1
			EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID
	END

/* Delete records not matching criteria or zero value entries if appropriate */
SELECT	@procDebugMessage = 'Deletion of data not valid for criteria'

IF @criDebug = 1
	EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

IF @criOption <> 4
	DELETE	res
	FROM	#tmpResult res (NOLOCK)
	WHERE	res.StartDate <= @criStopDate
			AND res.StopDate >= @criStartDate
			AND (@criFamilyID > 0
					AND res.FamilyID <> @criFamilyID
				OR @criChildID > 0
					AND res.ChildID <> @criChildID
				OR @criProgramID > 0
					AND res.ProgramID <> @criProgramID
				OR @criScheduleID > 0
					AND res.ScheduleID IS NOT NULL
					AND res.ScheduleID <> @criScheduleID
				OR @criProviderID > 0
					AND res.ProviderID <> @criProviderID
				OR @criSpecialistID > 0
					AND NOT EXISTS	(SELECT *
									FROM	tlnkFamilySpecialist fs (NOLOCK)
									WHERE	res.FamilyID = fs.FamilyID
											AND fs.SpecialistID = @criSpecialistID)
				OR res.Total = 0
					AND @optRemoveZeroValue = 1)
	OPTION	(KEEP PLAN)

IF @criDebug = 1
	EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

/* Insert results into final result table */
SELECT	@procDebugMessage = 'Insertion into final result table'

IF @criDebug = 1
	EXEC spCalc_DebugHeader @procDebugMessage, @procDebugStartTime OUTPUT

IF @criOption = 1
	INSERT	tblTimeSheetResult
		(UserID,
		FamilyID,
		ChildID,
		ProgramID,
		ScheduleID,
		ScheduleDetailID,
		ProviderID,
		StartDate,
		StopDate,
		Evening,
		Weekend,
		PaymentTypeID,
		RateTypeID,
		CareTimeID,
		Rate,
		Units,
		Total,
		InExcessOfMonthlyRMR,
		Breakfast,
		Lunch,
		Snack,
		Dinner,
		RMRCapped)
	SELECT	@criUserID,
			FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			StartDate,
			StopDate,
			Evening,
			Weekend,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			InExcessOfMonthlyRMR,
			Breakfast,
			Lunch,
			Snack,
			Dinner,
			@procRMRCapped
	FROM	#tmpResult
	OPTION	(KEEP PLAN)

IF @criOption = 2
	BEGIN
		INSERT	tblProjectionResult
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			ExtendedSchedule,
			PeriodStart,
			PeriodStop,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			InExcessOfMonthlyRMR)
		SELECT	FamilyID,
				ChildID,
				ProgramID,
				ScheduleID,
				ScheduleDetailID,
				ProviderID,
				ExtendedSchedule,
				StartDate,
				StopDate,
				PaymentTypeID,
				RateTypeID,
				CareTimeID,
				Rate,
				Units,
				Total,
				InExcessOfMonthlyRMR
		FROM	#tmpResult
		OPTION	(KEEP PLAN)

		INSERT	tblProjectionError
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ProviderID,
			ErrorDate,
			ErrorCode,
			ErrorDesc)
		SELECT	FamilyID,
				ChildID,
				ProgramID,
				ScheduleID,
				ProviderID,
				ErrorDate,
				ErrorCode,
				ErrorDesc
		FROM	#tmpError
		OPTION	(KEEP PLAN)
	END

IF @criOption = 3
	BEGIN
		INSERT	tblFamilyFeeResult
			(FamilyID,
			ChildID,
			ProgramID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			StartDate,
			StopDate,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			UserID)
		SELECT	FamilyID,
				ChildID,
				ProgramID,
				ScheduleID,
				ScheduleDetailID,
				ProviderID,
				StartDate,
				StopDate,
				PaymentTypeID,
				RateTypeID,
				CareTimeID,
				Rate,
				Units,
				Total,
				@criUserID
		FROM	#tmpResult
		OPTION	(KEEP PLAN)

		UPDATE	ff
		SET		ProviderID = sub.ProviderID
		FROM	tblFamilyFeeResult ff
				JOIN	(SELECT	tmp.ChildID,
								tmp.StartDate,
								tmp.StopDate,
								s.ProviderID
						FROM	#tmpResult tmp
								JOIN tblSchedule s (NOLOCK)
									ON tmp.ChildID = s.ChildID
						WHERE	s.PrimaryProvider = 1
								AND (tmp.StartDate <= s.StopDate
									OR s.StopDate IS NULL)
								AND (tmp.StopDate >= s.StartDate
									OR s.StartDate IS NULL)
								AND tmp.ProviderID IS NULL) sub
					ON ff.ChildID = sub.ChildID
						AND ff.StartDate = sub.StartDate
						AND ff.StopDate = sub.StopDate
	END

IF @criOption = 4
	BEGIN
		UPDATE	b
		SET		b.AttendancePaymentTypeID = r.PaymentTypeID,
				b.AttendanceRateTypeID = r.RateTypeID,
				b.AttendanceCareTimeID = r.CareTimeID,				
				b.AttendanceRate = r.Rate,
				b.AttendanceUnits = r.Units,
				b.AttendanceTotal = r.Total,
				b.AttendanceProgramID = r.ProgramID
		FROM	#tmpBilledFees b
				JOIN #tmpResult r
					ON b.StartDate = r.StartDate
						AND b.StopDate = r.StopDate
						AND b.FamilyID = r.FamilyID

		INSERT #tmpBilledFees
			(FamilyID,
			 ChildID,
 			 ProviderID,
			 StartDate,
			 StopDate,
			 UserID,
			 AttendancePaymentTypeID,
			 AttendanceRateTypeID,
			 AttendanceCareTimeID,
			 AttendanceRate,
			 AttendanceUnits,
			 AttendanceTotal,
			 AdjustmentTotal,
			 AttendanceProgramID)
			SELECT	r.FamilyID,
					r.ChildID,
 					r.ProviderID,
					r.StartDate,
					r.StopDate,
					@criUserID,
					r.PaymentTypeID,
					r.RateTypeID,
					r.CareTimeID,
					r.Rate,
					r.Units,
					r.Total,
					0, --AdjustmentTotal,
					r.ProgramID
		FROM	#tmpResult r
				LEFT JOIN	(SELECT FamilyID,
									StartDate
							FROM	#tmpBilledFees) sub
					ON r.FamilyID = sub.FamilyID
						AND r.StartDate = sub.StartDate
		WHERE	sub.StartDate IS NULL

		UPDATE  #tmpBilledFees
		SET		AdjustmentTotal = ISNULL(AttendanceTotal, 0) - ISNULL(Total, 0)

		UPDATE	b
		SET		b.InvoiceID = sub.InvoiceID
		FROM	#tmpBilledFees b
				JOIN	(SELECT	DISTINCT 
								FamilyID,
								InvoiceID,
								DATEPART(MONTH, StartDate) AS MonthDate
						FROM	#tmpBilledFees
						WHERE	InvoiceID <> 0) sub
					ON b.FamilyID = sub.FamilyID
						AND DATEPART(MONTH, b.StartDate) = sub.MonthDate
		WHERE	b.InvoiceID IS NULL 
				OR b.InvoiceID = 0

		INSERT	tblFamilyFeeAdjustmentResult
			(FamilyID,
			ChildID,
			ProgramID,
			InvoiceID,
			ScheduleID,
			ScheduleDetailID,
			ProviderID,
			StartDate,
			StopDate,
			PaymentTypeID,
			RateTypeID,
			CareTimeID,
			Rate,
			Units,
			Total,
			UserID,
			RealProgramID,
			RealPaymentTypeID,
			RealRateTypeID,
			RealCareTimeID,
			RealRate,
			RealUnits,
			RealTotal,
			AdjustmentTotal)
		SELECT	b.FamilyID,
				b.ChildID,
				b.ProgramID,
				b.InvoiceID,
				0,
				0,
				b.ProviderID,
				b.StartDate,
				b.StopDate,
				b.PaymentTypeID,
				b.RateTypeID,
				b.CareTimeID,
				b.Rate,
				b.Units,
				b.Total,
				@criUserID,
				AttendanceProgramID,
				AttendancePaymentTypeID,
				AttendanceRateTypeID,
				AttendanceCareTimeID,
				AttendanceRate,
				AttendanceUnits,
				AttendanceTotal,
				AdjustmentTotal
		FROM	#tmpBilledFees b
		WHERE	AdjustmentTotal <> 0 
				OR ( AdjustmentTotal = 0 AND ProgramID <> AttendanceProgramID)
		OPTION	(KEEP PLAN)
	END

IF @criDebug = 1
	EXEC spCalc_DebugFooter @procDebugMessage, @procDebugStartTime, @procCalculationID

IF @criDebug = 1
	PRINT 'Processing complete'

IF @criDebug = 0
	SET NOCOUNT OFF

IF @criDebug = 1
	BEGIN
		PRINT	''
		PRINT	'Calculation completed at ' + CONVERT(VARCHAR, GETDATE(), 8)
	END
