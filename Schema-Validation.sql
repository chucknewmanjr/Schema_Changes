if not exists (select * from sys.triggers where name = 't_SchemaChange' and parent_class_desc = 'DATABASE')
	throw 50000, 'The SchemaValidation feature is dependent on the SchemaChange feature.', 1;

if SCHEMA_ID('SchemaValidation') is null 
	exec ('create schema [SchemaValidation] authorization [dbo];');

if OBJECT_ID('[SchemaValidation].[Rule]') is null
	create table [SchemaValidation].[Rule] (
		RuleCode varchar(50) not null
			constraint PK_Validation_SchemaValidation_RuleCode primary key,
		FailureMessage varchar(200) not null,
		CommandText nvarchar(MAX) not null,
		UpdatedOn datetime not null,
		UpdatedBy sysname not null,
		StatusID tinyint not null,
			constraint CK_SchemaValidation_Rule_StatusID 
			check (StatusID in (1, 2, 3, 4)),
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
-- This proc replaced ExpectedResults with LatestResults.
-- This is done by the user if latestResults appear to be better than ExistingResults.
--     EXEC [SchemaValidation].[p_SetExpectedResultsToLatest] @RuleCode='IF01'
create or alter proc [SchemaValidation].[p_SetExpectedResultsToLatest]
	@RuleCode varchar(50)
as
	set nocount on;

	update [SchemaValidation].[Rule]
	set ExpectedResults = LatestResults,
		UpdatedOn = SYSDATETIME(),
		UpdatedBy = SYSTEM_USER
	where RuleCode = @RuleCode;
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
-- Inserts or updates [SchemaValidation].[Rule] table.
create or alter proc [SchemaValidation].[p_SetRule]
	@RuleCode varchar(50),
	@FailureMessage varchar(200),
	@CommandText nvarchar(MAX)
as
	set nocount on;

	update [SchemaValidation].[Rule]
	set FailureMessage = @FailureMessage, 
		CommandText = @CommandText, 
		UpdatedOn = SYSDATETIME(),
		UpdatedBy = SYSTEM_USER
	where RuleCode = @RuleCode;

	if @@ROWCOUNT = 0 begin;
		insert [SchemaValidation].[Rule] (
			RuleCode,
			FailureMessage,
			CommandText,
			StatusID,
			UpdatedBy,
			UpdatedOn
		)
		values (
			@RuleCode,
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
-- Called by the [SchemaValidation].[p_ValidateSchema] proc
-- or by the user after fixing a failure.
-- It executes single rule from the [SchemaValidation].[Rule] table.
-- If the results match expectations, then the rule is set to SUCCESS.
-- The @EventID parameter can be left NULL if it's not known.
-- It's the EventID from a SchemaChange, which might be in some other database.
--		EXEC @Status_ID = [SchemaValidation].[p_ValidateRule] @RuleCode='DEFAULT-NAMING-1';
create or alter proc [SchemaValidation].[p_ValidateRule]
	@RuleCode varchar(50),
	@EventID int = NULL -- NULL means no event data
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
	from [SchemaValidation].[Rule]
	where RuleCode = @RuleCode;

	if @ExistingStatusID <> [SchemaValidation].[f_StatusID]('DISABLED')
		return @ExistingStatusID;

	-- The SQL in @CommandText returns a table of data.
	-- But what's needed is an XML string that can be stored in the Rule table.
	set @CommandText = 'set @ResultsInside = (' + @CommandText + ' for xml path)';

	-- sp_executesql can pass that XML fro the inside to the outside.
	exec sp_executesql @CommandText, N'@ResultsInside xml out', @ResultsInside=@ResultsOutside out;

	-- In order to compare the results to expectations,
	-- the XML must get converted into rows.
	insert @ExpectedResultsTable select cast(c.query('.') as nvarchar(max)) from @ExpectedResults.nodes('row') t(c);

	-- That goes for the expected results too.
	insert @ResultsOutsideTable select cast(c.query('.') as nvarchar(max)) from @ResultsOutside.nodes('row') t(c);

	-- If the results have a row that is not in the expected rows,
	-- then that's a failure.
	set @NewStatusID = IIF(
		exists (
			select * from @ResultsOutsideTable 
			except 
			select * from @ExpectedResultsTable
		),
		[SchemaValidation].[f_StatusID]('FAILURE'),
		[SchemaValidation].[f_StatusID]('SUCCESS')
	);

	update [SchemaValidation].[Rule]
	set StatusID = @NewStatusID,
		LatestResults = @ResultsOutside,
		ElapsedMilliseconds = DATEDIFF(millisecond, @ValidationStart, SYSDATETIME()),
		SchemaChangeEventID = @EventID,
		LastSuccessfulSchemaChangeEventID = IIF(
			@NewStatusID = [SchemaValidation].[f_StatusID]('SUCCESS'),
			ISNULL(@EventID, LastSuccessfulSchemaChangeEventID),
			LastSuccessfulSchemaChangeEventID
		),
		ValidatedOn = sysdatetime(),
		ValidatedBy = SYSTEM_USER
	where RuleCode = @RuleCode;

	return @NewStatusID;
go

-- ----------------------------------------------------------------------------
-- Called by the database level trigger in the same database.
-- It executes each of the rules in the [SchemaValidation].[Rule] table.
-- There's a time limit on how many it checks.
-- It starts with the rule that has gone the longest without a check.
create or alter proc [SchemaValidation].[p_ValidateSchema] 
	@DatabaseName sysname,
	@EventID int
as
	set nocount on;

	-- Build a select statement that contains the database name 
	-- that is used to store schema changes.
	declare @CommandText nvarchar(max) = concat('
		select concat('' ('', 
			format(PostTime, ''M/d/yyyy h:mmtt''), ''; '', 
			TriggerEventTypeName, '' '', 
			DatabaseName + ''.'' + 
			ObjectName, ''; '', 
			LoginName, '')''
		)
		from [', @DatabaseName, '].[SchemaChange].[v_SchemaChange]
		where EventID = ', @EventID, ';'
	);

	declare @SchemaChangeTable table (SchemaChange varchar(max));

	-- If the select fails, it shouldn't prevent the rest of the proc from running.
	begin try;
		insert @SchemaChangeTable exec (@CommandText);
	end try 
	begin catch;
		print error_message();
	end catch;

	declare @Rules table (Enum int identity, RuleCode varchar(50));

	-- Latest on top. That way, the rule that has gone the longest goes first.
	insert @Rules (RuleCode)
	select RuleCode 
	from [SchemaValidation].[Rule]
	where StatusID <> [SchemaValidation].[f_StatusID]('DISABLED')
	order by ValidatedOn desc; 

	declare @ThisEnum int = (select MAX(Enum) from @Rules);
	declare @RuleCode varchar(50);
	declare @FailureMessage varchar(200);
	declare @StatusID tinyint;
	declare @SchemaChange varchar(max) = (select SchemaChange from @SchemaChangeTable);
	declare @LoopStarted datetime = SYSDATETIME();

	while @ThisEnum > 0 begin;
		begin try;
			select @RuleCode = RuleCode from @Rules where Enum = @ThisEnum;

			select @FailureMessage = FailureMessage
			from [SchemaValidation].[Rule]
			where RuleCode = @RuleCode;

			-- ----------------------------------------------------------------
			-- Execute this rule individually.
			EXEC @StatusID = [SchemaValidation].[p_ValidateRule] @RuleCode=@RuleCode, @EventID=@EventID;
			-- ----------------------------------------------------------------

			-- If the rule failed, print it. Don't throw an error.
			if @StatusID = [SchemaValidation].[f_StatusID]('FAILURE') begin
				print CONCAT(
					'Schema Validation Rule violation occured: ', @FailureMessage, @SchemaChange, 
					'; For more, EXEC [SchemaValidation].[p_GetResults] ''', @RuleCode, ''';'
				);
			end;
		end try
		begin catch;
			-- If an error occured, don't rethrow it. Just print it.
			print CONCAT(ERROR_PROCEDURE(), ' #', ERROR_NUMBER(), ' line:', ERROR_LINE(), ' -- ', ERROR_MESSAGE());
		end catch;

		-- If rules exceed a tenth of a second, stop running rules.
		if DATEDIFF(millisecond, @LoopStarted, SYSDATETIME()) > 100 break; -- 100 means 0.1 seconds

		-- decrement the value.
		set @ThisEnum -= 1;
	end;
go

-- ----------------------------------------------------------------
-- Called by [SchemaValidation].[p_GetResults] twice.
-- Returns the XML as a resultset.
--     EXEC [SchemaValidation].[p_GetTableFromXML] 'Expected Results', '<row><a>1</a><b>2</b></row><row><a>3</a><b>4</b></row>';
create or alter proc [SchemaValidation].[p_GetTableFromXML]
	@Source sysname,
	@XML xml
as
	set nocount on;

	-- If there's no XML, return one row with NULL results.
	if @XML is null begin;
		select @Source as [Source], NULL as Results;

		return;
	end;

	declare @Row table (RowNum int identity, RowXML xml);

	-- First, the XML is parsed by row.
	insert @Row (RowXML) select c.query('.') from @XML.nodes('row') t(c);

	-- Then, calumn values get parsed into rows.
	select r.RowNum, 
		c.value('local-name(.)', 'sysname') as ColumnName, 
		c.value('.', 'sysname') as Val
	into #unpivot
	from @Row r
	cross apply r.RowXML.nodes('row/*') t(c);

	-- Finally, build SQL that pivots the rows into columns.
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
-- (1) the rule (2) the expected results (3) the latest results (4) instructions.
--     EXEC [SchemaValidation].[p_GetResults]  @RuleCode='DEFAULT-NAMING-1';
create or alter proc [SchemaValidation].[p_GetResults]
	@RuleCode varchar(50)
as
	set nocount on;

	select r.RuleCode, s.StatusName, r.CommandText
	from [SchemaValidation].[Rule] r
	left join (values 
		('TO-DO', 1), 
		('SUCCESS', 2), 
		('FAILURE', 3), 
		('DISABLED', 4)
	) s (StatusName, StatusID) on s.StatusID = r.StatusID
	WHERE r.RuleCode = @RuleCode;

	declare @ExpectedResults XML;
	declare @LatestResults XML;

	select @ExpectedResults = ExpectedResults, @LatestResults = LatestResults
	from [SchemaValidation].[Rule]
	WHERE RuleCode = @RuleCode

	exec [SchemaValidation].[p_GetTableFromXML] @Source='Expected Results', @XML=@ExpectedResults;

	exec [SchemaValidation].[p_GetTableFromXML] @Source='Latest Results', @XML=@LatestResults;

	select *
	from (values
		('Later schema changes may have resolved the issue. '),
		('If the status is SUCCESS, '),
		('then the issue has been resolved.'),
		('If the status is FAILURE, you can try 3 things: '),
		('(1) If none of the latest results are actually issues, '),
		('    run this:'),
		('        EXEC [SchemaValidation].[p_SetExpectedResultsToLatest] ''' + @RuleCode + ''';'),
		('(2) Make additional schema changes '),
		('    to correct the issue and rerun the rule.'),
		('        EXEC [SchemaValidation].[p_ValidateRule] ''' + @RuleCode + ''';'),
		('        EXEC [SchemaValidation].[p_GetResults] ''' + @RuleCode + ''';'),
		('(3) Update the CommandText of the rule '),
		('    to allow more conditions and rerun the rule.')
	) t (Instructions);
go


