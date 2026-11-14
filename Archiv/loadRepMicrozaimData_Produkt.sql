USE [dwh2]
GO
/****** Объект:  StoredProcedure [finAnalytics].[loadRepMicrozaimData_Produkt]    Дата создания скрипта: 01.10.2026 17:01:04 ******/ 
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [finAnalytics].[loadRepMicrozaimData_Produkt] 
    @historyDaysCount int   ---Параметр кол-ва последних дней для пересчета, если -1  считает всю историю
AS
BEGIN
	declare @sp_name NVARCHAR(255) = OBJECT_NAME(@@PROCID)
	--старт лог
       declare @log_IsError bit=0
       declare @log_Mem nvarchar(2000)	='Ok'
       declare @mainPrc nvarchar(255)=''
      if (select OBJECT_ID( N'tempdb..#mainPrc')) is not null
                          set @mainPrc=(select top(1) sp_name from #mainPrc)
      exec finAnalytics.sys_log @sp_name,0, @mainPrc
	declare @subjectHeader  nvarchar(250) ='Микрозаймы:агрегация по продуктам', @subject nvarchar(250)
	declare @msgFloor nvarchar(max) =concat(char(10),'Отработала процедура: ',@sp_name)
	declare @message nvarchar(max)=''
       
begin try
 
	--таблица по тз 265 Отчет по выдачам
	
    drop table if exists #dopFina265
	select
        produkt=l1.produkt
        ,repdate=l1.ОтчетнаяДата
        ,dsclient=sum(l1.dsclient)
        ,kp=sum(l1.kp)
	into #dopFina265
    from (
		select
			produkt=isnull(dwh2.finAnalytics.nomenk2prod (nomgroup.Наименование),'Продукт не определен')
            ,dsclient=iif(a.kt in ('20803','47422','20501'),a.Сумма,0) 
		    ,kp=iif(a.kt in ('60323','60332'),a.Сумма,0) 
            ,ОтчетнаяДата
	    from #BankReg a
		left join stg._1cUMFO.Справочник_БНФОДоговорыКредитовИДепозитов dog on a.СубконтоDt2_Ссылка=dog.Ссылка
		left join stg._1cUMFO.Справочник_НоменклатурныеГруппы nomgroup on dog.АЭ_НоменклатурнаяГруппа=nomgroup.Ссылка
		 ) l1
     group by l1.ОтчетнаяДата,l1.produkt
	
	--- таблица по тз 329 Разбивка выдач на каналы
	drop table if exists #dopFina329
	select
		repdate=dat
		,agent= case 
					when agent='БАНК ПСБ ПАО г. Ярославль' then 'psb'
					when agent='ТБАНК АО' then 'tba'
					when agent='EcommPay' then 'ecp'
                end
		,produkt
		,summ=sum(summ)
	into #dopFina329
	from (
		select
			dat=ОтчетнаяДата
			,agent=iif(isnull(dwh2.finAnalytics.nomenk2prod (nomgroup.Наименование),'Продукт не определен')='Автокредит' 
						and agn.Наименование not in ('ТБАНК АО','EcommPay')
						,'БАНК ПСБ ПАО г. Ярославль'
						, agn.Наименование)
				,summ=a.Сумма
			,produkt=isnull(dwh2.finAnalytics.nomenk2prod (nomgroup.Наименование),'Продукт не определен')
		from #BankReg a
		inner join dwh2.finAnalytics.getVidOper(9) v9 on a.reg=v9.reg
		left join stg._1cUMFO.Справочник_БНФОДоговорыКредитовИДепозитов dog on a.СубконтоDt2_Ссылка=dog.Ссылка
		left join stg._1cUMFO.Справочник_НоменклатурныеГруппы nomgroup on dog.АЭ_НоменклатурнаяГруппа=nomgroup.Ссылка
		left join stg._1cUMFO.Справочник_Контрагенты agn on a.СубконтоCt1_Ссылка=agn.Ссылка and agn.ПометкаУдаления=0x00
		where a.dt='48801'  and a.kt='47422'
		) l1
	where (agent in ('ТБАНК АО','БАНК ПСБ ПАО г. Ярославль','EcommPay') 
		or produkt='Автокредит')
	group by dat,agent,produkt


	--
 begin tran  
	declare @startDate date = dateadd(day,-@historyDaysCount,getdate())

    --Заполнение временной таблицы дат всем диапазоном
    if @historyDaysCount = -1
		begin 
			truncate table dwh2.finAnalytics.repMicrozaim_Produkt
			set @startDate='2025-01-01'
		end
    else 
		--Очистка таблицы результата по выбранному перечню дат
		delete from dwh2.finAnalytics.repMicrozaim_Produkt
				where repdate >= @startDate
	

	insert into dwh2.finAnalytics.repMicrozaim_Produkt (repdate, produkt, produktInSales,ds,kp,psb,ecp,tba)
	select
		repdate
		,produkt
		,produktInSales=produktInSales
		,ds=ds
		,kp=kp
		,psb=sum(isnull(psb,0))
		,ecp=sum(isnull(ecp,0))
		,tba=sum(isnull(tba,0))

	from (
			select
				repdate=l1.repdate
				,produkt=l1.produkt
				,produktInSales=l1.produktInSales
				,ds=isnull(f265.dsclient,0)
				,kp=isnull(f265.kp,0)
				,psb=iif(f329.agent='psb',f329.summ,0)
				,ecp=iif(f329.agent='ecp',f329.summ,0)
				,tba=iif(f329.agent='tba',f329.summ,0)

			from (
				select
					repdate=micro.repdate
					,produkt=isnull(dwh2.finAnalytics.nomenk2prod (nomgroup.Наименование),'Продукт не определен')
					,produktInSales=sum(a.Сумма)
	
				from dwh2.finAnalytics.repMicrozaim micro
				left join #BankReg a on micro.repdate=a.ОтчетнаяДата
				left join stg._1cUMFO.Справочник_БНФОДоговорыКредитовИДепозитов dog on a.СубконтоDt2_Ссылка=dog.Ссылка
				left join stg._1cUMFO.Справочник_НоменклатурныеГруппы nomgroup on dog.АЭ_НоменклатурнаяГруппа=nomgroup.Ссылка
				where a.dt in ('48801','48701','49401')	and micro.repdate>=@startDate
				group by micro.repdate,micro.sales,micro.salesRR,[finAnalytics].[nomenk2prod] (nomgroup.Наименование)
				 )l1
			left join #dopFina265 f265 on l1.repdate=f265.repdate and l1.produkt=f265.produkt
			left join #dopFina329 f329 on l1.repdate=f329.repdate and l1.produkt=f329.produkt
		) l2
	group by repdate,produkt,produktInSales, ds,kp 
		

 commit tran	
	
	set @subject=@subjectHeader 
	set @message=concat('Данные обновлены ',iif( @historyDaysCount=-1 ,'полностью',concat('за период: ',@historyDaysCount)))
	set @message=concat(@message,@msgFloor)
	exec finAnalytics.sendEmail @subject ,@message ,@strRcp = '1'
	
	--финиш
   exec dwh2.finAnalytics.sys_log  @sp_name,1, @mainPrc
end try
 begin catch
    IF @@TRANCOUNT > 0
     ROLLBACK TRANSACTION
   ----Лог
   set  @log_IsError =1
   set  @log_Mem =ERROR_MESSAGE()
   exec finAnalytics.sys_log  @sp_name,1, @mainPrc,  @log_IsError,  @log_Mem
   ---
	set @message=CONCAT('Ошибка выполнения процедуры - ',@sp_name,'. Ошибка ',ERROR_MESSAGE()) 
	set @subject='Ошибка! '
	set @message=@message
	exec finAnalytics.sendEmail @subject ,@message ,@strRcp = '1'
   ;throw 51000 
			,@message
			,1;    
  end catch
END
