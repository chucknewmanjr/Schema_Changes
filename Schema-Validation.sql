if not exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	throw 50000, 'The SchemaValidation feature is dependent on the SchemaChange feature.', 1;

if SCHEMA_ID('SchemaValidation') is null 
	exec ('create schema [SchemaValidation] authorization [dbo];');

if OBJECT_ID('[SchemaValidation].[SchemaValidationRule]') is null
	create table [SchemaValidation].[SchemaValidationRule] (
		SchemaValidationRuleID smallint not null identity
			constraint PK_SchemaValidation_SchemaValidationRule primary key,
		SchemaValidationRuleCode varchar(50) not null
			constraint UI_Validation_SchemaValidation_SchemaValidationRuleCode unique,
		FailureMessage varchar(200) not null,
		CommandText nvarchar(MAX) not null,
		UpdatedOn datetime not null,
		UpdatedBy sysname not null,
		StatusID tinyint not null,
		ExpectedResults xml null,
		LatestResults xml null,
		ElapsedMilliseconds int null,
		SchemaChangeEventID int null,
		LastSuccessfulSchemaChangeEventID int null,
		ValidatedOn datetime null,
		ValidatedBy sysname null
	);
go

-- ----------------------------------------------------------------
-- Rather than getting the XML results yourself,
-- this proc gets the current results for you and updates Expected_Results.
-- Called by [SchemaValidation].[p_Set_Schema_Validation].
--     EXEC [SchemaValidation].[p_Set_Schema_Validation_Expected_Results_to_Current] @Schema_Validation_Code='IF01'
create or alter proc [SchemaValidation].[p_SetExpectedResultsToLatest]
	@SchemaValidationRuleCode varchar(50)
as
	set nocount on;

	update [SchemaValidation].[SchemaValidationRule]
	set ExpectedResults = LatestResults,
		UpdatedOn = SYSDATETIME(),
		UpdatedBy = SYSTEM_USER
	where SchemaValidationRuleCode = @SchemaValidationRuleCode;
go

-- ----------------------------------------------------------------------------
create or alter function [SchemaValidation].[f_StatusID](@StatusName varchar(10))
returns tinyint begin;
	return
		case @StatusName
			when 'TO-DO' then 1
			when 'SUCCESS' then 2
			when 'FAILURE' then 3
			when 'DISABLED' then 4
			else null
		end;
end;
go

-- ----------------------------------------------------------------------------
-- Inserts or updates [SchemaValidation].[SchemaValidationRule] table.
create or alter proc [SchemaValidation].[p_SetRule]
	@SchemaValidationRuleCode varchar(50),
	@FailureMessage varchar(200),
	@CommandText nvarchar(MAX)
as
	set nocount on;

	update [SchemaValidation].[SchemaValidationRule]
	set FailureMessage = @FailureMessage, 
		CommandText = @CommandText, 
		UpdatedOn = SYSDATETIME(),
		UpdatedBy = SYSTEM_USER
	where SchemaValidationRuleCode = @SchemaValidationRuleCode;

	if @@ROWCOUNT = 0 begin;
		insert [SchemaValidation].[SchemaValidationRule] (
			SchemaValidationRuleCode,
			FailureMessage,
			CommandText,
			StatusID,
			UpdatedBy,
			UpdatedOn
		)
		values (
			@SchemaValidationRuleCode,
			@FailureMessage,
			@CommandText,
			[SchemaValidation].[f_StatusID]('TO-DO'),
			SYSTEM_USER,
			SYSDATETIME()
		);

		if @@ROWCOUNT = 0 THROW 50000, 'p_SetRule failed', 1;
	end;
go

-- ----------------------------------------------------------------------------
-- Called by the db trigger and [SchemaValidation].[p_Get_Schema_Validation_Details].
--		EXEC @Status_ID = [SchemaValidation].[p_ValidateRule] @Schema_Validation_Code='PK-1', @Schema_Change_ID=NULL
create or alter proc [SchemaValidation].[p_ValidateRule]
	@SchemaValidationRuleCode varchar(50),
	@SchemaChangeEventID int = NULL -- NULL means no event data
as
	set nocount on;

	declare @CommandText nvarchar(MAX);
	declare @ExpectedResults xml;
	declare @ExistingStatusID tinyint;
	declare @NewStatusID tinyint;
	declare @ValidationStart datetime = SYSDATETIME();
	declare @ResultsOutside xml;

	declare @ExpectedResultsTable table (RowXML nvarchar(max));

	declare @ResultsOutsideTable table (RowXML nvarchar(max));

	select
		@CommandText = CommandText,
		@ExpectedResults = ExpectedResults,
		@ExistingStatusID = StatusID
	from [SchemaValidation].[SchemaValidationRule]
	where SchemaValidationRuleCode = @SchemaValidationRuleCode;

	if @ExistingStatusID <> [SchemaValidation].[f_StatusID]('DISABLED')
		return @ExistingStatusID;

	set @CommandText = 'set @ResultsInside = (' + @CommandText + ' for xml path)';

	exec sp_executesql @CommandText, N'@ResultsInside xml out', @ResultsInside=@ResultsOutside out;

	insert @ExpectedResultsTable select cast(c.query('.') as nvarchar(max)) from @ExpectedResults.nodes('row') t(c);

	insert @ResultsOutsideTable select cast(c.query('.') as nvarchar(max)) from @ResultsOutside.nodes('row') t(c);

	set @NewStatusID = IIF(
		exists (
			select * from @ResultsOutsideTable 
			except 
			select * from @ExpectedResultsTable
		),
		[SchemaValidation].[f_StatusID]('FAILURE'),
		[SchemaValidation].[f_StatusID]('SUCCESS')
	);

	update [SchemaValidation].[SchemaValidationRule]
	set StatusID = @NewStatusID,
		LatestResults = @ResultsOutside,
		ElapsedMilliseconds = DATEDIFF(millisecond, @ValidationStart, SYSDATETIME()),
		SchemaChangeEventID = @SchemaChangeEventID,
		LastSuccessfulSchemaChangeEventID = IIF(
			@NewStatusID = [SchemaValidation].[f_StatusID]('SUCCESS'),
			ISNULL(@SchemaChangeEventID, LastSuccessfulSchemaChangeEventID),
			LastSuccessfulSchemaChangeEventID
		),
		ValidatedOn = sysdatetime(),
		ValidatedBy = SYSTEM_USER
	where SchemaValidationRuleCode = @SchemaValidationRuleCode;

	return @NewStatusID;
go

create or alter proc [SchemaValidation].[p_ValidateSchema] 
	@DatabaseName sysname,
	@SchemaChangeEventID int
as

	declare @CommandText nvarchar(max) = concat('
		select concat('' ('', 
			format(PostTime, ''M/d/yyyy h:mmtt''), ''; '', 
			TriggerEventTypeName, '' '', 
			DatabaseName + ''.'' + 
			ObjectName, ''; '', 
			LoginName, '')''
		)
		from [', @DatabaseName, '].[SchemaChange].[v_SchemaChange]
		where SchemaChangeEventID = ', @SchemaChangeEventID, ';'
	);

	declare @SchemaChangeTable table (SchemaChange varchar(max));

	begin try;
		insert @SchemaChangeTable exec (@CommandText);
	end try 
	begin catch;
		print error_message();
	end catch;

	declare @SchemaChange varchar(max) = (select SchemaChange from @SchemaChangeTable);
	declare @SchemaValidationRuleCode varchar(50);
	declare @FailureMessage varchar(200);
	declare @StatusID tinyint;
	declare @LoopStarted datetime = SYSDATETIME();

	declare @Rules table (Enum int identity, SchemaValidationRuleCode varchar(50));

	insert @Rules (SchemaValidationRuleCode)
	select SchemaValidationRuleCode 
	from [SchemaValidation].[SchemaValidationRule]
	where StatusID <> [SchemaValidation].[f_StatusID]('DISABLED')
	order by ValidatedOn desc;

	declare @ThisEnum int = (select MAX(Enum) from @Rules);

	while @ThisEnum > 0 begin;
		begin try;
			select @SchemaValidationRuleCode = SchemaValidationRuleCode from @Rules where Enum = @ThisEnum;

			select
				@FailureMessage = FailureMessage
			from [SchemaValidation].[SchemaValidationRule]
			where SchemaValidationRuleCode = @SchemaValidationRuleCode;

			EXEC @StatusID = [SchemaValidation].[p_ValidateRule] @SchemaValidationRuleCode, @SchemaChangeEventID;

			if @StatusID = [SchemaValidation].[f_StatusID]('FAILURE') begin
				print CONCAT(
					'WARNING: ', @FailureMessage, 
					@SchemaChange, 
					'; For more, EXEC [SchemaValidation].[p_GetDetails] ''', @SchemaValidationRuleCode, ''';'
				);
			end;
		end try
		begin catch;
			print CONCAT(ERROR_PROCEDURE(), ' #', ERROR_NUMBER(), ' line:', ERROR_LINE(), ' -- ', ERROR_MESSAGE());
		end catch;

		if DATEDIFF(millisecond, @LoopStarted, SYSDATETIME()) > 100 break; -- 100 means 0.1 seconds

		set @ThisEnum -= 1;
	end;
go

-- ----------------------------------------------------------------
-- Returns the XML as a resultset.
-- Called by [Tools].[p_Get_Schema_Validation_Details].
--		EXEC [Tools].[p_Get_Schema_Validation_Table] 1, '<row><a>1</a><b>2</b></row><row><a>3</a><b>4</b></row>', 'test';
create or alter proc [SchemaValidation].[p_GetTableFromXML]
	@Source sysname,
	@XML xml
as
	set nocount on;

	if @XML is null begin;
		select @Source as [Source], NULL as Results;

		return;
	end;

	declare @Row table (RowNum int identity, RowXML xml);

	insert @Row (RowXML) select c.query('.') from @XML.nodes('row') t(c);

	select r.RowNum, 
		c.value('local-name(.)', 'sysname') as ColumnName, 
		c.value('.', 'sysname') as Val
	into #unpivot
	from @Row r
	cross apply r.RowXML.nodes('row/*') t(c);

	declare @sql nvarchar(MAX) = '';

	select @sql = @sql + ', MIN(IIF(ColumnName=''' + ColumnName + ''', Val, NULL)) as ' + ColumnName
	from #unpivot
	group by ColumnName;

	set @sql = 'select ''' + @Source + ''' as Source' + @sql + ' from #unpivot group by RowNum;';

	set ansi_warnings off;

	exec (@sql);
go

-- ----------------------------------------------------------------
-- Returns 4 resultsets about the current test status.
-- Better than SELECT * FROM [SchemaValidation].[vw_Schema_Validation]
-- Depends on [SchemaValidation].[p_Run_Schema_Validation] and [SchemaValidation].[p_Get_Schema_Validation_Table].
--		EXEC [SchemaValidation].[p_Get_Schema_Validation_Details] 1
create or alter proc [SchemaValidation].[p_GetDetails]
	@SchemaValidationRuleCode varchar(50)
as
	set nocount on;

	select s.StatusName, r.CommandText
	from [SchemaValidation].[SchemaValidationRule] r
	left join (values 
		('TO-DO', 1), 
		('SUCCESS', 2), 
		('FAILURE', 3), 
		('DISABLED', 4)
	) s (StatusName, StatusID) on s.StatusID = r.StatusID
	WHERE SchemaValidationRuleCode = @SchemaValidationRuleCode;

	declare @ExpectedResults XML;
	declare @LatestResults XML;

	select @ExpectedResults = ExpectedResults, @LatestResults = LatestResults
	from [SchemaValidation].[SchemaValidationRule]
	WHERE SchemaValidationRuleCode = @SchemaValidationRuleCode

	exec [SchemaValidation].[p_GetTableFromXML] 'Expected Results', @ExpectedResults;

	exec [SchemaValidation].[p_GetTableFromXML] 'Latest Results', @LatestResults;

	select *
	from (values
		('Later schema changes may have corrected the issue.'),
		('Check the status. It might now be in success.'),
		('If not, you can try to fix the issue,'),
		('rerun the rule and check these results again.'),
		('    EXEC [SchemaValidation].[p_ValidateRule] ''' + @SchemaValidationRuleCode + ''';'),
		('    EXEC [SchemaValidation].[p_GetDetails] ''' + @SchemaValidationRuleCode + ''';'),
		('If the latest results are correct, run this:'),
		('    EXEC [SchemaValidation].[p_SetExpectedResultsToLatest] ''' + @SchemaValidationRuleCode + ''';')
	) t (Instructions);
go



