{% macro snowflake__create_external_table(source_node) %}

    {%- set columns = source_node.columns.values() -%}
    {%- set external = source_node.external -%}
    {%- set partitions = external.partitions -%}
    {%- set infer_schema = external.infer_schema -%}
    {%- set infer_schema_incl_filename_column = external.infer_schema_incl_filename_column -%}
    {%- set infer_schema_incl_filelastchanged_column = external.infer_schema_incl_filelastchanged_column -%}
    {%- set infer_schema_incl_rownumber_column = external.infer_schema_incl_rownumber_column -%}
    {%- set infer_schema_incl_partition_column = external.infer_schema_incl_partition_column -%}
    {%- set ignore_case = external.ignore_case or false  -%}

    {% if infer_schema %}
        {% set query_infer_schema %}
            select * from table( infer_schema( location=>'{{external.location}}', file_format=>'{{external.file_format}}', ignore_case=> {{ ignore_case }}) )
        {% endset %}
        {% if execute %}
            {% set columns_infer = run_query(query_infer_schema) %}
        {% endif %}
    {% endif %}

    {%- set is_csv = dbt_external_tables.is_csv(external.file_format) -%}

{# https://docs.snowflake.net/manuals/sql-reference/sql/create-external-table.html #}
{# This assumes you have already created an external stage #}

{% set ddl %}
    create or replace external table {{source(source_node.source_name, source_node.name)}}
    {%- if columns or partitions or infer_schema -%}
    (
        {%- if partitions -%}{%- for partition in partitions %}
            {{partition.name}} {{partition.data_type}} as {{partition.expression}}{{- ',' if not loop.last or columns|length > 0 or infer_schema -}}
        {%- endfor -%}{%- endif -%}
        {%- if not infer_schema -%}
            {%- for column in columns %}
                {%- set column_quoted = adapter.quote(column.name) if column.quote else column.name %}
                {%- set column_alias -%}
                    {%- if 'alias' in column and column.quote -%}
                        {{adapter.quote(column.alias)}}
                    {%- elif 'alias' in column -%}
                        {{column.alias}}
                    {%- else -%}
                        {{column_quoted}}
                    {%- endif -%}
                {%- endset %}
                {%- set col_expression -%}
                    {%- if column.expression -%}
                        {{column.expression}}
                    {%- else -%}
                        {%- if ignore_case -%}
                        {%- set col_id = 'value:c' ~ loop.index if is_csv else 'GET_IGNORE_CASE($1, ' ~ "'"~ column_quoted ~"'"~ ')' -%}
                        {%- else -%}
                        {%- set col_id = 'value:c' ~ loop.index if is_csv else 'value:' ~ column_quoted -%}
                        {%- endif -%}
                        (case when is_null_value({{col_id}}) or lower({{col_id}}) = 'null' then null else {{col_id}} end)
                    {%- endif -%}
                {%- endset %}
                {{column_alias}} {{column.data_type}} as ({{col_expression}}::{{column.data_type}})
                {{- ',' if not loop.last -}}
            {% endfor %}
        {% else %}
        {%- for column in columns_infer %}
            {#– quote the raw column name –#}
            {%- set raw_name   = column[0] -%}
            {%- set data_type  = column[1] -%}
            {%- set quoted_name = adapter.quote(raw_name) -%}
            {#– build the expression, using quoted_name –#}
            {%- set col_expression -%}
                {%- if ignore_case -%}
                    {%- set col_id = 'GET_IGNORE_CASE($1, ' ~ "'" ~ quoted_name ~ "'" ~ ')' -%}
                {%- else -%}
                    {%- set col_id = 'value:' ~ quoted_name -%}
                {%- endif -%}
                (case
                    when is_null_value({{ col_id }})
                      or lower({{ col_id }}) = 'null'
                    then null
                    else {{ col_id }}
                 end)
            {%- endset -%}
            {{ quoted_name }} {{ data_type }} as ({{ col_expression }}::{{ data_type }})
            {{- ',' if not loop.last
                 or infer_schema_incl_filename_column
                 or infer_schema_incl_filelastchanged_column
                 or infer_schema_incl_rownumber_column
                 or infer_schema_incl_partition_column -}}
        {%- endfor %}
        {%- if infer_schema_incl_filename_column -%}
            source_filename VARCHAR AS (METADATA$FILENAME)
            {{- ',' if not infer_schema_incl_filelastchanged_column or infer_schema_incl_rownumber_column or infer_schema_incl_partition_column -}}
        {%- endif -%}
        {%- if infer_schema_incl_filelastchanged_column -%}
            source_file_last_modified TIMESTAMP_NTZ AS (METADATA$FILE_LAST_MODIFIED)
            {{- ',' if not infer_schema_incl_rownumber_column or infer_schema_incl_partition_column -}}
        {%- endif -%}
        {%- if infer_schema_incl_rownumber_column -%}
            source_file_row_number BIGINT AS (METADATA$FILE_ROW_NUMBER)
            {{- ',' if not infer_schema_incl_partition_column -}}
        {%- endif -%}
        {%- if infer_schema_incl_partition_column -%}
            {%- if partitions -%}{%- for partition in partitions %}
                 ','{{partition.name}}{{- ',' if not loop.last  -}}
            {%- endfor -%}{%- endif -%}
        {%- endif -%}
    {%- endif -%}
    )
    {%- endif -%}
    {% if partitions %} partition by ({{partitions|map(attribute='name')|join(', ')}}) {% endif %}
    location = {{external.location}} {# stage #}
    {% if external.auto_refresh in (true, false) -%}
      auto_refresh = {{external.auto_refresh}}
    {%- endif %}
    {% if external.refresh_on_create in (true, false) -%}
      refresh_on_create = {{external.refresh_on_create}}
    {%- endif %}
    {% if external.aws_sns_topic -%}
      aws_sns_topic = '{{external.aws_sns_topic}}'
    {%- endif %}
    {% if external.table_format | lower == "delta" %}
      refresh_on_create = false
    {% endif %}
    {% if external.pattern -%} pattern = '{{external.pattern}}' {%- endif %}
    {% if external.integration -%} integration = '{{external.integration}}' {%- endif %}
    file_format = {{external.file_format}}
    {% if external.table_format -%} table_format = '{{external.table_format}}' {%- endif %}
{% endset %}
{# {{ log('ddl: ' ~ ddl, info=True) }} #}
{{ ddl }};
{% endmacro %}
