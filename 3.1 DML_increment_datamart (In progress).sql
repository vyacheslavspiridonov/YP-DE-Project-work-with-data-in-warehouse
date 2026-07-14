WITH
dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT     
            dcs.customer_id AS customer_id,
            dcs.customer_name AS customer_name,
            dcs.customer_address AS customer_address,
            dcs.customer_birthday AS customer_birthday,
            dcs.customer_email AS customer_email,	
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type, 
            fo.order_completion_date - fo.order_created_date AS diff_order_date, 
            fo.order_status AS order_status, 
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period, 
            crd.customer_id AS exist_customer_id,
            dc.craftsman_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm
	FROM dwh.f_order fo
    	INNER JOIN dwh.d_craftsman dc	ON fo.craftsman_id = dc.craftsman_id
    	INNER JOIN dwh.d_customer dcs	ON fo.customer_id = dcs.customer_id
    	INNER JOIN dwh.d_product dp 	ON fo.product_id = dp.product_id
    	LEFT JOIN dwh.customer_report_datamart crd ON dcs.customer_id = crd.customer_id
	WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') 	FROM dwh.load_dates_customer_report_datamart)) OR
		  (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') 	FROM dwh.load_dates_customer_report_datamart)) OR
          (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') 	FROM dwh.load_dates_customer_report_datamart)) OR
          (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') 	FROM dwh.load_dates_customer_report_datamart))
),
dwh_update_delta AS (
-- делаем выборку заказчиков, по которым были изменения в DWH. 
-- По этим заказчикам данные в витрине нужно будет обновить
    SELECT  distinct
            dd.exist_customer_id AS customer_id 
    FROM dwh_delta dd 
    WHERE dd.exist_customer_id IS NOT NULL 
),
dwh_delta_insert_result AS ( 
-- Делаем расчёт витрины по новым данным. 
-- Этой информации по заказчикам в рамках расчётного периода раньше не было, это новые данные. 
-- Их можно просто вставить (insert) в витрину без обновленияю.
    SELECT  
            T5.customer_id 			AS customer_id,
            T5.customer_name 		AS customer_name,
            T5.customer_address 	AS customer_address,
            T5.customer_birthday 	AS customer_birthday,
            T5.customer_email 		AS customer_email,
            T5.customer_money 		AS customer_money,
            T5.platform_money 		AS platform_money,			
            T5.count_order 			AS count_order,
            T5.avg_price_order 		AS avg_price_order,
            T5.product_type 		AS top_product_category,
            T5.top_craftsman_id 	AS top_craftsman_id,
            T5.median_time_order_completed 	AS median_time_order_completed, 
            T5.count_order_created 			AS count_order_created,
            T5.count_order_in_progress 		AS count_order_in_progress,
            T5.count_order_delivery 		AS count_order_delivery,
            T5.count_order_done 			AS count_order_done,
            T5.count_order_not_done 		AS count_order_not_done,
            T5.report_period 				AS report_period 
	FROM (
		SELECT     
			-- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины,
			-- и применяем оконную функцию для определения самой популярной категории товаров и самого популярного мастера.
			*,
			-- Заменил RANK на ROW_NUMBER(), так как критически важно избежать задвоения строк:
			-- Если будет у покупателя два продукта с рангом 1 и два мастера с рангом 1, то это уже 4 строки вместо 1-й
			ROW_NUMBER() OVER(PARTITION BY T2.customer_id ORDER BY count_product 		  DESC) 	AS rank_count_product,
            ROW_NUMBER() OVER(PARTITION BY T2.customer_id ORDER BY count_craftsman_orders DESC) 	AS rank_count_craftsman_orders
		FROM ( 
			SELECT 
			-- В этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, 
			-- \кроме столбца с самой популярной категорией товаров у мастера. 
			-- Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN.
				T1.customer_id 			AS customer_id, 
                T1.customer_name 		AS customer_name,
                T1.customer_address 	AS customer_address,
                T1.customer_birthday 	AS customer_birthday,
                T1.customer_email 		AS customer_email,
                SUM(T1.product_price) 	AS customer_money,		-- Потрачено итого
                SUM(T1.product_price) * 0.1 AS platform_money,	-- Комиссия платформы
                COUNT(distinct order_id) 	AS count_order,		-- Всего заказов
                AVG(T1.product_price) 		AS avg_price_order,	-- Ср. стоимость заказа
                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed, -- Медианное время выполнения заказа заказчика
                SUM(CASE WHEN T1.order_status = 'created' 		THEN 1 ELSE 0 END) AS count_order_created,	-- Заказов в статусе "Создан"
                SUM(CASE WHEN T1.order_status = 'in progress' 	THEN 1 ELSE 0 END) AS count_order_in_progress, -- Заказов в статусе "В процессе"
                SUM(CASE WHEN T1.order_status = 'delivery'		THEN 1 ELSE 0 END) AS count_order_delivery, -- Заказов в статусе "В доставке"
                SUM(CASE WHEN T1.order_status = 'done' 			THEN 1 ELSE 0 END) AS count_order_done, 	-- Заказов в статусе "Готов"
                SUM(CASE WHEN T1.order_status != 'done' 		THEN 1 ELSE 0 END) AS count_order_not_done, -- Заказов не в статусе "Создан"
                T1.report_period AS report_period
            FROM dwh_delta AS T1
            WHERE T1.exist_customer_id IS NULL
            GROUP BY T1.customer_id, T1.customer_name
                   , T1.customer_address, T1.customer_birthday
                   , T1.customer_email, T1.report_period 
            ) AS T2 
            INNER JOIN (
            	SELECT
            	-- Эта выборка поможет определить самый популярный товар у заказчика. 
                -- Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. 
                -- Для данных этой выборки можно применить оконную функцию, 
                -- 	которая и покажет самую популярную категорию товаров у заказчика.
                	dd.customer_id AS customer_id_for_product_type, 
                    dd.product_type, 
                    COUNT(dd.product_id) AS count_product
                FROM dwh_delta AS dd
                GROUP BY dd.customer_id, dd.product_type) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
            INNER JOIN (
            	-- Аналогичная выборка, но с другой группировкой.
                -- Вычисление популярности мастеров среди заказчиков по количеству заказов.
                SELECT 
                	dd.customer_id  	AS customer_id_for_popular_craftsman, 
					dd.craftsman_id 	AS top_craftsman_id, 
					COUNT(dd.order_id)  AS count_craftsman_orders
				FROM dwh_delta AS dd
				GROUP BY dd.customer_id, dd.craftsman_id) AS T4 ON T2.customer_id = T4.customer_id_for_popular_craftsman
        ) AS T5
        WHERE T5.rank_count_product = 1 AND T5.rank_count_craftsman_orders = 1
        -- условие помогает оставить в выборке только строки с:
        -- а) первой по популярности категорией товаров
        -- б) первым по популярности мастером в разрезе заказчика
),
dwh_delta_update_result AS ( 
-- делаем перерасчёт для существующих записей витрины, так как данные обновились за отчётные периоды. 
-- Логика похожа на insert, но нужно достать конкретные данные из DWH.
    SELECT 
            T5.customer_id 			AS customer_id,				
            T5.customer_name 		AS customer_name,			
            T5.customer_address 	AS customer_address,
            T5.customer_birthday 	AS customer_birthday,	
            T5.customer_email 		AS customer_email,			
            T5.customer_money 		AS customer_money,			
            T5.platform_money 		AS platform_money,
            T5.count_order 			AS count_order, 
            T5.avg_price_order 		AS avg_price_order,
            T5.product_type 		AS top_product_category,
            T5.top_craftsman_id		AS top_craftsman_id,
            T5.median_time_order_completed 	AS median_time_order_completed,
            T5.count_order_created 			AS count_order_created,
            T5.count_order_in_progress 		AS count_order_in_progress,
            T5.count_order_delivery 		AS count_order_delivery, 
            T5.count_order_done 			AS count_order_done, 
            T5.count_order_not_done 		AS count_order_not_done,
            T5.report_period 				AS report_period 
	FROM (
 		SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
        	*,
        	-- Заменил RANK на ROW_NUMBER(), так как критически важно избежать задвоения строк:
            -- Если будет у покупателя два продукта с рангом 1 и два мастера с рангом 1, то это уже 4 строки вместо 1-й
        	ROW_NUMBER() OVER(PARTITION BY T2.customer_id ORDER BY count_product 		  DESC) AS rank_count_product,
        	ROW_NUMBER() OVER(PARTITION BY T2.customer_id ORDER BY count_craftsman_orders DESC) AS rank_count_craftsman_orders                
    	FROM (
        	SELECT 
        	-- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, 
        	--  \кроме столбца с самой популярной категорией товаров у заказчика. 
        	-- Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
            	T1.customer_id 			AS customer_id,
                T1.customer_name 		AS customer_name,
                T1.customer_address 	AS customer_address,
                T1.customer_birthday 	AS customer_birthday,
                T1.customer_email 		AS customer_email,
                SUM(T1.product_price) 	AS customer_money,
                SUM(T1.product_price) * 0.1 	AS platform_money,
                COUNT(order_id) 				AS count_order,
                AVG(T1.product_price) 			AS avg_price_order,
                AVG(T1.customer_age) 			AS avg_age_customer,
                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) 		AS median_time_order_completed,
                SUM(CASE WHEN T1.order_status = 'created' 		THEN 1 ELSE 0 END) 	AS count_order_created, 
                SUM(CASE WHEN T1.order_status = 'in progress'	THEN 1 ELSE 0 END) 	AS count_order_in_progress, 
                SUM(CASE WHEN T1.order_status = 'delivery' 		THEN 1 ELSE 0 END) 	AS count_order_delivery, 
                SUM(CASE WHEN T1.order_status = 'done' 			THEN 1 ELSE 0 END) 	AS count_order_done, 
                SUM(CASE WHEN T1.order_status != 'done' 		THEN 1 ELSE 0 END) 	AS count_order_not_done,
                T1.report_period 													AS report_period
            FROM (
            	SELECT     
                	-- в этой выборке достаём из DWH обновлённые или новые данные по заказчикам, которые уже есть в витрине
                    dcs.customer_id 			AS customer_id,
                    dcs.customer_name 		AS customer_name,
                    dcs.customer_address 	AS customer_address,
                    dcs.customer_birthday 	AS customer_birthday,
                    dcs.customer_email 		AS customer_email,
                    fo.order_id 			AS order_id,			
                    dp.product_id 			AS product_id,
                    dp.product_price 		AS product_price,
                    dp.product_type 		AS product_type,
                    DATE_PART('year', AGE(dcs.customer_birthday)) 		AS customer_age,
                    fo.order_completion_date - fo.order_created_date 	AS diff_order_date,
                    fo.order_status 									AS order_status, 
                    TO_CHAR(fo.order_created_date, 'yyyy-mm') 			AS report_period
                FROM dwh.f_order fo 
                    INNER JOIN dwh.d_craftsman dc  ON fo.craftsman_id = dc.craftsman_id 
                    INNER JOIN dwh.d_customer  dcs ON fo.customer_id  = dcs.customer_id 
                    INNER JOIN dwh.d_product   dp  ON fo.product_id   = dp.product_id
                    INNER JOIN dwh_update_delta ud ON fo.customer_id  = ud.customer_id ) AS T1
                GROUP BY T1.customer_id, T1.customer_name
                	   , T1.customer_address, T1.customer_birthday
                	   , T1.customer_email, T1.report_period
               	) AS T2 
                    INNER JOIN (
                    	SELECT 
                        	-- Эта выборка поможет определить самый популярный товар у заказчика. 
                            -- Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. 
                            -- Для данных этой выборки можно применить оконную функцию, 
                            -- \которая и покажет одну самую популярную категорию товаров у заказчика.
                            dd.customer_id AS customer_id_for_product_type, 
                            dd.product_type, 
                            COUNT(dd.product_id) AS count_product
                        FROM dwh_delta AS dd
                        GROUP BY dd.customer_id, dd.product_type) AS T3 ON T2.customer_id = T3.customer_id_for_product_type
                    INNER JOIN (
                    	-- Аналогичная выборка, но с другой группировкой.
                        -- Вычисление популярности мастеров среди заказчиков по количеству заказов.
                        SELECT 
                        	dd.customer_id  	AS customer_id_for_popular_craftsman, 
							dd.craftsman_id 	AS top_craftsman_id, 
							COUNT(dd.order_id) 	AS count_craftsman_orders
						FROM dwh_delta AS dd
						GROUP BY dd.customer_id, dd.craftsman_id) AS T4 ON T2.customer_id = T4.customer_id_for_popular_craftsman 
	) AS T5 
    WHERE T5.rank_count_product = 1 and t5.rank_count_craftsman_orders = 1
    ORDER BY report_period
),
insert_delta AS ( 
	-- выполняем insert новых расчитанных данных для витрины 
    INSERT INTO dwh.customer_report_datamart (
        customer_id,
        customer_name,
        customer_address,
        customer_birthday,
        customer_email,
        customer_money,
        platform_money,
        count_order,
        avg_price_order,
        median_time_order_completed,
        top_product_category,
        top_craftsman_id,
        count_order_created,
        count_order_in_progress,
        count_order_delivery, 
        count_order_done,
        count_order_not_done, 
        report_period
    ) SELECT 
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            median_time_order_completed,
            top_product_category,
        	top_craftsman_id,
            count_order_created, 
            count_order_in_progress,
            count_order_delivery, 
            count_order_done, 
            count_order_not_done,
            report_period 
      FROM dwh_delta_insert_result
),
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим заказчикам
    UPDATE dwh.customer_report_datamart SET
        customer_name = updates.customer_name,
        customer_address = updates.customer_address,
        customer_birthday = updates.customer_birthday,
        customer_email = updates.customer_email,
        customer_money = updates.customer_money,
        platform_money = updates.platform_money, 					
        count_order = updates.count_order, 
        avg_price_order = updates.avg_price_order,
        median_time_order_completed = updates.median_time_order_completed,  
        top_craftsman_id = updates.top_craftsman_id,
        top_product_category = updates.top_product_category, 
        count_order_created = updates.count_order_created, 
        count_order_in_progress = updates.count_order_in_progress, 
        count_order_delivery = updates.count_order_delivery, 
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done, 
        report_period = updates.report_period
    FROM (
        SELECT 
            customer_id,
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            customer_money,
            platform_money,
            count_order,
            avg_price_order,
            median_time_order_completed,
            top_product_category,
            top_craftsman_id,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period 
            FROM dwh_delta_update_result) AS updates
    WHERE dwh.customer_report_datamart.customer_id = updates.customer_id
),
insert_load_date AS ( 
	-- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, 
	-- \которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_customer_report_datamart (load_dttm)
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(customers_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
    FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE