# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"
require "debug"
require "mocha/minitest"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_paths.first + "/files"
  ActiveSupport::TestCase.fixtures :all
end

module BlockLogDeviceTimeoutExceptions
  def write(...)
    # Prevents Timeout exceptions from occurring during log writing, where they will be swallowed
    # See https://bugs.ruby-lang.org/issues/9115
    Thread.handle_interrupt(Timeout::Error => :never, Timeout::ExitException => :never) { super }
  end
end

Logger::LogDevice.prepend(BlockLogDeviceTimeoutExceptions)
class ExpectedTestError < RuntimeError; end


class ActiveSupport::TestCase
  include ConfigurationTestHelper, ProcessesTestHelper, JobsTestHelper

  setup do
    @_on_thread_error = SolidQueue.on_thread_error
    SolidQueue.on_thread_error = silent_on_thread_error_for(ExpectedTestError, @_on_thread_error)
    ActiveJob::QueueAdapters::SolidQueueAdapter.stopping = false
  end

  teardown do
    SolidQueue.on_thread_error = @_on_thread_error
    JobBuffer.clear

    if SolidQueue.supervisor_pidfile && File.exist?(SolidQueue.supervisor_pidfile)
      File.delete(SolidQueue.supervisor_pidfile)
    end

    unless self.class.use_transactional_tests
      SolidQueue::Job.destroy_all
      SolidQueue::Process.destroy_all
      SolidQueue::Semaphore.delete_all
      SolidQueue::RecurringTask.delete_all
      JobResult.delete_all
    end
  end

  private
    def wait_while_with_timeout(timeout, &block)
      wait_while_with_timeout!(timeout, &block)
    rescue Timeout::Error
    end

    def wait_while_with_timeout!(timeout, &block)
      Timeout.timeout(timeout) do
        skip_active_record_query_cache do
          while block.call
            sleep 0.05
          end
        end
      end
    end

    # Allow skipping AR query cache, necessary when running test code in multiple
    # forks. The queries done in the test might be cached and if we don't perform
    # any non-SELECT queries after previous SELECT queries were cached on the connection
    # used in the test, the cache will still apply, even though the data returned
    # by the cached queries might have been updated, created or deleted in the forked
    # processes.
    def skip_active_record_query_cache(&block)
      SolidQueue::Record.uncached(&block)
    end

    # Silences specified exceptions during the execution of a block
    #
    # @param [Exception, Array<Exception>] expected an Exception or an array of Exceptions to ignore
    # @yield Executes the provided block with specified exception(s) silenced
    def silence_on_thread_error_for(expected, &block)
      current_proc = SolidQueue.on_thread_error

      SolidQueue.with(on_thread_error: silent_on_thread_error_for(expected, current_proc)) do
        block.call
      end
    end

    def silent_on_thread_error_for(exceptions, on_thread_error)
      ->(exception) do
        unless Array(exceptions).any? { |e| exception.instance_of?(e) }
          on_thread_error.call(exception)
        end
      end
    end

    # Waits until the given block returns truthy or the timeout is reached.
    # Similar to other helper methods in this file but waits *for* a condition
    # instead of *while* it is true.
    def wait_for(timeout: 1.second, interval: 0.05)
      Timeout.timeout(timeout) do
        loop do
          break if skip_active_record_query_cache { yield }
          sleep interval
        end
      end
    end
end
