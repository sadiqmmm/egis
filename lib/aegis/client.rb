# frozen_string_literal: true

require 'aws-sdk-athena'

module Aegis
  class Client
    QUERY_STATUS_MAPPING = {
      'QUEUED' => :queued,
      'RUNNING' => :running,
      'SUCCEEDED' => :finished,
      'FAILED' => :failed,
      'CANCELLED' => :cancelled
    }.freeze

    S3_URL_PATTERN = %r{^s3://(?<bucket>\S+?)/(?<key>\S+)$}.freeze

    EXECUTE_QUERY_START_TIME = 1
    EXECUTE_QUERY_MULTIPLIER = 2

    private_constant :QUERY_STATUS_MAPPING, :EXECUTE_QUERY_START_TIME, :EXECUTE_QUERY_MULTIPLIER, :S3_URL_PATTERN

    def initialize(aws_athena_client: nil, configuration: Aegis.configuration)
      @configuration = configuration
      @aws_athena_client = aws_athena_client || Aws::Athena::Client.new(athena_config)
    end

    def database(database_name)
      Database.new(self, database_name)
    end

    def execute_query(query, work_group: nil, database: nil, output_location: nil, async: true)
      query_execution_id = aws_athena_client.start_query_execution(
        query_execution_params(query, work_group, database, output_location)
      ).query_execution_id

      return query_execution_id if async

      waiting_time = EXECUTE_QUERY_START_TIME
      until (query_status = wait_for_execution_end(query_execution_id))
        sleep(waiting_time)
        waiting_time *= EXECUTE_QUERY_MULTIPLIER
      end

      raise Aegis::QueryExecutionError, query_status.message unless query_status.finished?

      query_status
    end

    def query_status(query_execution_id)
      resp = aws_athena_client.get_query_execution({query_execution_id: query_execution_id})
      Aegis::QueryStatus.new(
        QUERY_STATUS_MAPPING.fetch(resp.query_execution.status.state),
        resp.query_execution.status.state_change_reason,
        parse_output_location(resp)
      )
    end

    private

    attr_reader :aws_athena_client, :configuration

    def query_execution_params(query, work_group, database, output_location)
      work_group_params = work_group || configuration.work_group

      params = {query_string: query}
      params[:work_group] = work_group_params if work_group_params
      params[:query_execution_context] = {database: database} if database
      params[:result_configuration] = {output_location: output_location} if output_location
      params
    end

    def athena_config
      config = {}
      config[:region] = configuration.aws_region if configuration.aws_region
      config[:access_key_id] = configuration.aws_access_key_id if configuration.aws_access_key_id
      config[:secret_access_key] = configuration.aws_secret_access_key if configuration.aws_secret_access_key
      config
    end

    def wait_for_execution_end(query_execution_id)
      status = query_status(query_execution_id)

      status unless status.queued? || status.running?
    end

    def parse_output_location(resp)
      url = resp.query_execution.result_configuration.output_location

      matched_data = S3_URL_PATTERN.match(url)

      QueryOutputLocation.new(url, matched_data[:bucket], matched_data[:key])
    end
  end
end
