/*
	drop proc if exists [Tools].[p_Get_Schema_Validation_Table];
	drop proc if exists [Tools].[p_Run_Schema_Validation];
	drop proc if exists [Tools].[p_Set_Schema_Validation];
	drop proc if exists [Tools].[p_Get_Schema_Validation_Details];
	drop proc if exists [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current];
	drop view if exists [Tools].[vw_Schema_Validation];
	drop table if exists [Tools].[Schema_Validation];
*/

if OBJECT_ID('[Tools].[Schema_Change]') is null
	throw 50000, 'Schema_Validation is dependant on Schema_Change', 1;

if OBJECT_ID('[Tools].[Schema_Validation]') is null begin;
	create table [Tools].[Schema_Validation] (
		Schema_Validation_Code varchar(50) not null
			constraint PK_Tools_Schema_Validation primary key,
		Failure_Message varchar(450) not null,
		Instructions varchar(MAX) not null, -- SQL that must set @Results
		Is_XML_Results bit not null, -- 1 means XML
		Expected_Results varchar(MAX) null, -- typically, XML
		Status_ID tinyint not null, -- 0 means To-Do
		Validated_On datetime null,
		Updated_On datetime not null,
		Updated_By sysname not null,
		Elapsed_Milliseconds int null,
		Schema_Change_ID int null
			constraint FK_Tools_Schema_Validation_Schema_Change_ID
			references [Tools].[Schema_Change] (Schema_Change_ID),
		Last_Successful_Schema_Change_ID int null
			constraint FK_Tools_Schema_Validation_Last_Successful_Schema_Change_ID
			references [Tools].[Schema_Change] (Schema_Change_ID),
		Results varchar(MAX) null -- typically, XML
	);
end;
go

-- ----------------------------------------------------------------
-- Called by the trigger and [Tools].[p_Get_Schema_Validation_Details].
--		SELECT TOP 100 * FROM [Tools].[vw_Schema_Validation] ORDER BY 1 DESC
create or alter view [Tools].[vw_Schema_Validation] as
	select
		t.Schema_Validation_Code
		,t.Failure_Message
		,t.Instructions
		,t.Is_XML_Results
		,t.Expected_Results
		,tsv.Status_Value
		,t.Validated_On
		,t.Updated_On
		,t.Updated_By
		,t.Elapsed_Milliseconds
		,t.Schema_Change_ID
		,t.Results
		,e.[type_name]
		,e.Post_Time
		,e.Login_Name
		,e.[User_Name]
		,e.[Object_Name]
		,e.Command_Text
		,e.Alter_Table_Action_List
	from [Tools].[Schema_Validation] t
	join (
		values (0, 'To-Do'), (1, 'Disabled'), (2, 'Success'), (3, 'Failure')
	) tsv (Status_ID, Status_Value) on t.Status_ID = tsv.Status_ID
	left join [Tools].[VW_Schema_Change] e on t.Last_Successful_Schema_Change_ID + 1 = e.Schema_Change_ID;;
go

-- ----------------------------------------------------------------
-- Rather than getting the XML results yourself,
-- this proc gets the current results for you and updates Expected_Results.
-- Called by [Tools].[p_Set_Schema_Validation].
--     EXEC [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current] @Schema_Validation_Code='IF01'
create or alter proc [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current]
	@Schema_Validation_Code varchar(50)
as
	declare @Instructions nvarchar(MAX);
	declare @Is_XML_Results bit;
	declare @Results_Outside varchar(MAX);

	set nocount on;

	select 
		@Instructions = Instructions,
		@Is_XML_Results = Is_XML_Results,
		@Schema_Validation_Code = Schema_Validation_Code
	from [Tools].[Schema_Validation]
	where Schema_Validation_Code = @Schema_Validation_Code;

	if @@ROWCOUNT <> 1 throw 50000, 'No validation matches your entry', 1;

	if @Is_XML_Results = 1 set @Instructions = 'set @Results = (' + @Instructions + ' for xml path)';

	exec sp_executesql @Instructions, N'@Results varchar(MAX) out', @Results=@Results_Outside out;

	update [Tools].[Schema_Validation]
	set Expected_Results = @Results_Outside,
		Updated_On = SYSDATETIME(),
		Updated_By = SYSTEM_USER
	where Schema_Validation_Code = @Schema_Validation_Code;
go

-- ----------------------------------------------------------------
-- Inserts or updates [Tools].[Schema_Validation] table.
-- If you want it to fail if the validation already exists, set @Is_Insert_or_Update = to 0.
-- If you leave @Expected_Results = to NULL, it gets the current results and uses that.
-- About @Is_XML_Results -- One means the result is a resultset. It gets converted to XML.
--		The resultset gets stored and compared as XML. Zero means the Instructions set the result. 
--		EX: @Instructions = 'set @Results = CONVERT(varchar(MAX), HASHBYTES(''MD5'', 
--			(select LedgerTypeName from [Core].[LedgerType] order by 1 for json auto)), 2)'
-- Depends on [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current].
create or alter proc [Tools].[p_Set_Schema_Validation]
	@Schema_Validation_Code varchar(50),
	@Failure_Message varchar(450),
	@Instructions varchar(MAX),
	@Is_XML_Results bit = 1, -- Zero means results do not get converted from a resultset to XML
	@Expected_Results varchar(MAX) = NULL, -- NULL means go get the current results.
	@Is_Insert_or_Update bit = 1 -- Zero means fail if the validation already exists.
as
	declare @Row_Count int = 0;
	declare @To_Do_Status_ID tinyint = 0; -- 0 means To-Do

	set nocount on;

	if @Is_Insert_or_Update = 1 begin;
		update [Tools].[Schema_Validation]
		set Instructions = @Instructions, 
			Is_XML_Results = @Is_XML_Results, 
			Expected_Results = ISNULL(@Expected_Results, Expected_Results),
			Updated_On = SYSDATETIME(),
			Updated_By = SYSTEM_USER
		where Schema_Validation_Code = @Schema_Validation_Code;

		set @Row_Count = @@ROWCOUNT;
	end;

	if @Row_Count = 0 begin;
		insert [Tools].[Schema_Validation] (
			Schema_Validation_Code,
			Failure_Message,
			Instructions,
			Is_XML_Results,
			Expected_Results,
			Status_ID,
			Updated_On,
			Updated_By
		)
		values (
			@Schema_Validation_Code,
			@Failure_Message,
			@Instructions,
			@Is_XML_Results,
			@Expected_Results,
			@To_Do_Status_ID,
			SYSDATETIME(),
			SYSTEM_USER
		);

		if @@ROWCOUNT = 0 begin;
			THROW 50000, 'p_Set_Schema_Validation failed', 1;
		end;
	end;

	if @Expected_Results is null
		exec [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current] @Schema_Validation_Code=@Schema_Validation_Code;
go

-- ----------------------------------------------------------------
-- Returns the XML as a resultset.
-- Called by [Tools].[p_Get_Schema_Validation_Details].
--		EXEC [Tools].[p_Get_Schema_Validation_Table] 1, '<row><a>1</a><b>2</b></row><row><a>3</a><b>4</b></row>', 'test';
create or alter proc [Tools].[p_Get_Schema_Validation_Table]
	@Source sysname,
	@Is_XML_Results bit, -- One means convert XML to a resultset.
	@XML xml
as
	set nocount on;

	if @Is_XML_Results = 0 or @XML is null begin;
		select @Source as [Source], @XML as Results;

		return;
	end;

	declare @Row table (Row_Num int identity, Row_XML xml);

	insert @Row (Row_XML)
	select c.query('.')
	from @XML.nodes('row') t(c);

	select r.Row_Num, c.value('local-name(.)', 'sysname') as Column_Name, c.value('.', 'sysname') as Val
	into #unpivot
	from @Row r
	cross apply r.Row_XML.nodes('row/*') t(c);

	declare @sql nvarchar(MAX) = '';

	select @sql = @sql + ', MIN(IIF(Column_Name=''' + Column_Name + ''', Val, NULL)) as ' + Column_Name
	from #unpivot
	group by Column_Name;

	set @sql = 'select ''' + @Source + ''' as Source' + @sql + ' from #unpivot group by Row_Num;';

	set ansi_warnings off;

	exec (@sql);
go

-- ----------------------------------------------------------------
-- Called by the db trigger and [Tools].[p_Get_Schema_Validation_Details].
--		EXEC @Status_ID = [Tools].[p_Run_Schema_Validation] @Schema_Validation_Code='PK-1', @Schema_Change_ID=NULL
create or alter proc [Tools].[p_Run_Schema_Validation]
	@Schema_Validation_Code varchar(50),
	@Schema_Change_ID int = NULL -- NULL means no event data
as
	set nocount on;

	declare @Is_XML_Results bit;
	declare @Instructions nvarchar(MAX);
	declare @Expected_Results varchar(MAX);
	declare @Validation_Started datetime = SYSDATETIME();
	declare @Results_Outside varchar(MAX);
	declare @Existing_Status_ID tinyint;
	declare @New_Status_ID tinyint;

	declare @Disabled_Status_ID tinyint = 1; -- 1 means Disabled
	declare @Success_Status_ID tinyint = 2; -- 2 means Success
	declare @Failure_Status_ID tinyint = 3; -- 3 means Failure

	select
		@Is_XML_Results = Is_XML_Results,
		@Instructions = Instructions,
		@Expected_Results = Expected_Results,
		@Existing_Status_ID = Status_ID
	from [Tools].[Schema_Validation]
	where Schema_Validation_Code = @Schema_Validation_Code;

	if @Is_XML_Results = 1 set @Instructions = 'set @Results = (' + @Instructions + ' for xml path)';

	exec sp_executesql @Instructions, N'@Results varchar(MAX) out', @Results=@Results_Outside out;

	set @New_Status_ID = IIF(
		exists (SELECT @Results_Outside INTERSECT SELECT @Expected_Results),
		@Success_Status_ID,
		@Failure_Status_ID
	);

	if @Existing_Status_ID <> @Disabled_Status_ID
		update [Tools].[Schema_Validation]
		set Status_ID = @New_Status_ID,
			Validated_On = @Validation_Started,
			Elapsed_Milliseconds = DATEDIFF(millisecond, @Validation_Started, SYSDATETIME()),
			Schema_Change_ID = ISNULL(@Schema_Change_ID, Schema_Change_ID),
			Results = @Results_Outside,
			Last_Successful_Schema_Change_ID = IIF(
				@New_Status_ID = @Success_Status_ID,
				ISNULL(@Schema_Change_ID, Last_Successful_Schema_Change_ID),
				Last_Successful_Schema_Change_ID
			)
		where Schema_Validation_Code = @Schema_Validation_Code;

	return @New_Status_ID;
go

-- ----------------------------------------------------------------
-- Returns 4 resultsets about the current test status.
-- Better than SELECT * FROM [Tools].[vw_Schema_Validation]
-- Depends on [Tools].[p_Run_Schema_Validation] and [Tools].[p_Get_Schema_Validation_Table].
--		EXEC [Tools].[p_Get_Schema_Validation_Details] 1
create or alter proc [Tools].[p_Get_Schema_Validation_Details]
	@Schema_Validation_Code varchar(50)
as
	set nocount on;

	EXEC [Tools].[p_Run_Schema_Validation] @Schema_Validation_Code;

	select
		Schema_Validation_Code,
		Failure_Message,
		Status_Value,
		[type_name],
		Login_Name,
		[Object_Name],
		Command_Text,
		Alter_Table_Action_List,
		Instructions
	from [Tools].[vw_Schema_Validation]
	WHERE Schema_Validation_Code = @Schema_Validation_Code;

	declare @Is_XML_Results bit;
	declare @Results varchar(MAX);
	declare @Expected_Results varchar(MAX);

	select
		@Is_XML_Results=Is_XML_Results,
		@Expected_Results=Expected_Results,
		@Results=Results
	from [Tools].[vw_Schema_Validation]
	WHERE Schema_Validation_Code = @Schema_Validation_Code;

	exec [Tools].[p_Get_Schema_Validation_Table] 'Current Results', @Is_XML_Results, @Results;

	exec [Tools].[p_Get_Schema_Validation_Table] 'Expected Results', @Is_XML_Results, @Expected_Results;

	select CONCAT(
			'If the current results are correct, ' +
			'EXEC [Tools].[p_Set_Schema_Validation_Expected_Results_to_Current] ' +
			'@Schema_Validation_Code=''', @Schema_Validation_Code, ''''
		) as TIP;
go

create or alter proc [Tools].[p_Validate_Schema] @Schema_Change_ID int as
	declare @Loop_Started datetime = SYSDATETIME();
	declare @Disabled_Status_ID tinyint = 1; -- constant: 1 means Disabled
	declare @Failure_Status_ID tinyint = 3; -- constant: 3 means Failure

	-- variables set inside the loop
	declare @Schema_Validation_Code varchar(50);
	declare @Failure_Message nvarchar(450);
	declare @Login_Name sysname;
	declare @Post_Time datetime;
	declare @Event_Type_Name nvarchar(64);
	declare @Object_Name sysname;
	declare @Status_ID tinyint;

	declare @Test table (Enum int identity, Schema_Validation_Code varchar(50));

	insert @Test (Schema_Validation_Code)
	select Schema_Validation_Code from [Tools].[Schema_Validation]
	where Status_ID <> @Disabled_Status_ID
	order by Validated_On desc;

	declare @This int = (select MAX(Enum) from @Test);

	while @This > 0 begin;
		begin try;
			select @Schema_Validation_Code = Schema_Validation_Code from @Test where Enum = @This;

			select
				@Failure_Message = Failure_Message,
				@Login_Name = Login_Name,
				@Post_Time = Post_Time,
				@Event_Type_Name = [type_name],
				@Object_Name = [Object_Name]
			from [Tools].[vw_Schema_Validation]
			where Schema_Validation_Code = @Schema_Validation_Code;

			EXEC @Status_ID = [Tools].[p_Run_Schema_Validation] @Schema_Validation_Code, @Schema_Change_ID;

			if @Status_ID = @Failure_Status_ID begin
				print CONCAT(
					'WARNING: ', @Failure_Message, 
					IIF(@Login_Name is null, '', CONCAT(
						'. ', @Login_Name, ' ',
						FORMAT(@Post_Time, 'M/d/yy h:mmtt '),
						@Event_Type_Name, ' ',
						@Object_Name
					)), 
					'; For more, EXEC [Tools].[p_Get_Schema_Validation_Details] ''', @Schema_Validation_Code, ''';'
				);
			end;
		end try
		begin catch;
			print CONCAT(ERROR_PROCEDURE(), ' #', ERROR_NUMBER(), ' line:', ERROR_LINE(), ' -- ', ERROR_MESSAGE());
		end catch;

		if DATEDIFF(millisecond, @Loop_Started, SYSDATETIME()) > 500 break; -- 500 means .5 seconds

		set @This -= 1;
	end;
go
