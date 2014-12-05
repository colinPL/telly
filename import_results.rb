#!/usr/bin/env ruby

# This script adds test results in testrail from a finished beaker run
# It takes in a beaker junit file and a TestRail Testrun ID
# 
# It matches the beaker tests with TestRail testcases by looking for the 
#   test case ID in the beaker script. The combination of a test run and a test case
#   allows the script to add a result for a particular instance of a test case.
#   In TestRail parlance, this is confusingly called a test.
# From the TestRail API docs:
#   "In TestRail, tests are part of a test run and the test cases are part of the
#   related test suite. So, when you create a new test run, TestRail creates a test
#   for each test case found in the test suite of the run. You can therefore think
#   of a test as an “instance” of a test case which can have test results, comments 
#   and a test status.""

require 'optparse'
require 'nokogiri'
require 'yaml'
require 'pp'
require_relative 'testrail'


TESTRAIL_URL = 'https://testrail.ops.puppetlabs.net/index.php'
CREDENTIALS_FILE = 'credentials.yaml'

# Used for extracted the test case ID from beaker scripts
TESTCASE_ID_REGEX = /.*(?<jira_ticket>\w+-\d+).*[cC](?<testrun_id>\d+)/

# Testrail Status IDs
PASSED = 1
BLOCKED = 2
FAILED = 5


##################################
# Main
##################################

def main(options)
  # Get pass/fail/skips from junit file
  results = load_junit_results(options[:junit_file])

  puts "Run results:"
  puts "#{results[:passes].length} Passing"
  puts "#{results[:failures].length} Failing or Erroring"
  puts "#{results[:skips].length} Skipped"

  # Set results in testrail
  set_testrail_results(results, options[:junit_file], options[:testrun_id])
end


# Parses the command line options
def parse_opts
  options_hash = {}

  optparse = OptionParser.new do|parser|
    options_hash = {
      testrun_id: nil,
      junit_file: nil,
    }

    parser.on( '-t', '--testrun-id TESTRUN_ID', 'The testrun id' ) do |testrun_id|
      options_hash[:testrun_id] = testrun_id
    end

    parser.on( '-j', '--junit-folder JUNIT_FILE', 'Beaker junit file' ) do |junit_file|
      options_hash[:junit_file] = junit_file
    end

    parser.on( '-h', '--help', 'Display this screen' ) do
      puts parser
      exit
    end

    parser.parse!

    if not options_hash[:testrun_id] or not options_hash[:junit_file]
      puts "Error: Missing option(s)"
      puts parser
      exit
    end
  end

  options_hash
end


##################################
# TestRail API
##################################

# Load testrail credentials from file
#
# ==== Returns
#
# +hash+ - Contains testrail_username and testrail_password
#
# ==== Examples
#
# password = load_credentials()["testrail_password"]
def load_credentials()
  begin
    YAML.load_file(CREDENTIALS_FILE)  
  rescue
    puts "Error: Could not find credentials.yaml\nHave you copied credentials_template.yaml and filled in your info?"

    exit
    
  end
end


# Returns a testrail API object that talks to testrail
#
# ==== Attributes
#
# * +credentials+ - A hash containing at least two keys, testrail_username and testrail_password
# 
# ==== Returns
#
# +TestRail::APIClient+ - The API object for talking to TestRail
#
# ==== Examples
#
# api = get_testrail_api(load_credentials)
def get_testrail_api(credentials)
  client = TestRail::APIClient.new(TESTRAIL_URL)
  client.user = credentials["testrail_username"]
  client.password = credentials["testrail_password"]

  return client
end

# Sets the results in testrail. 
# Tests that have testrail API exceptions are kept track of in bad_results
#
# ==== Attributes
#
# * +results+ - A hash of lists of xml objects from the junit output file.
# * +junit_file+ - The path to the junit xml file
#   Needed for determining the path of the test file in add_failure, etc
# * +testrun_id+ - The TestRail test run ID
# 
# ==== Returns
#
# nil
#
def set_testrail_results(results, junit_file, testrun_id)
  testrail_api = get_testrail_api(load_credentials)

  # Results that couldn't be set in testrail for some reason
  bad_results = {}

  # passes
  results[:passes].each do |junit_result|
    begin
      add_pass(testrail_api, junit_result, junit_file, testrun_id)    
    rescue TestRail::APIError => e
      bad_results[junit_result[:name]] = e.message
    end
  end

  # Failures
  results[:failures].each do |junit_result|
    begin
      add_failure(testrail_api, junit_result, junit_file, testrun_id)    
    rescue TestRail::APIError => e
      bad_results[junit_result[:name]] = e.message
    end
  end

  # Skips
  results[:skips].each do |junit_result|
    begin
      add_skip(testrail_api, junit_result, junit_file, testrun_id)    
    rescue TestRail::APIError => e
      bad_results[junit_result[:name]] = e.message
    end
  end

  # Print error messages
  if not bad_results.empty?
    puts "Error: There were problems processing these test scripts:"
    bad_results.each do |test_script, error|
      puts "#{test_script}:\n\t#{error}"
    end
  end
end


# Adds a fail result to a testcase
# Adds a comment to the result with the error message from the test run
def add_failure(testrail_api, junit_result, junit_file, testrun_id)
  test_file_path = beaker_test_path(junit_file, junit_result)

  testcase_id = testcase_id_from_beaker_script(test_file_path)

  time_elapsed = make_testrail_time(junit_result[:time])

  # Make an appropriate comment for the test's error message
  error_message = junit_result.xpath('./failure').first[:message]
  testrail_comment = "Failed with message:\n#{error_message}"

  puts "\nSetting result for failed test case: #{testcase_id}"
  puts "Adding comment:\n#{testrail_comment}"

  # TODO add user ID to result
  testrail_api.send_post("add_result_for_case/#{testrun_id}/#{testcase_id}", 
    {
      status_id: FAILED,
      comment: testrail_comment,
      elapsed: time_elapsed,
    }
  )
end


# Adds a pass result to a testcase
def add_pass(testrail_api, junit_result, junit_file, testrun_id)
  test_file_path = beaker_test_path(junit_file, junit_result)

  testcase_id = testcase_id_from_beaker_script(test_file_path)

  time_elapsed = make_testrail_time(junit_result[:time])

  puts "\nSetting result for passing test case: #{testcase_id}"

  testrail_api.send_post("add_result_for_case/#{testrun_id}/#{testcase_id}", 
    {
      status_id: PASSED,
      elapsed: time_elapsed
    }
  )
end


# Adds a pass result to a testcase
# Adds a comment with the skip message
def add_skip(testrail_api, junit_result, junit_file, testrun_id)
  test_file_path = beaker_test_path(junit_file, junit_result)

  testcase_id = testcase_id_from_beaker_script(test_file_path)

  time_elapsed = make_testrail_time(junit_result[:time])

  # Make an appropriate comment for the test's skip message
  skip_message = junit_result.xpath('system-out').first.text
  testrail_comment = "Skipped with message:\n#{skip_message}"

  puts "\nSetting result for skipped test case: #{testcase_id}"
  puts "Adding comment:\n#{testrail_comment}"

  testrail_api.send_post("add_result_for_case/#{testrun_id}/#{testcase_id}", 
    {
      status_id: BLOCKED,
      comment: testrail_comment,
      elapsed: time_elapsed
    }
  )
end


# Returns a string that testrail accepts as an elapsed time
# Input from beaker is a float in seconds, so it rounds it to the 
# nearest second, and adds an 's' at the end
# 
# Testrail throws an exception if it gets "0s", so it returns a 
# minimum of "1s"
#
# ==== Attributes
#
# * +seconds_string+ - A string that contains only a number, the elapsed time of a test
# 
# ==== Returns
#
# +string+ - The elapsed time of the test run, rounded and with an 's' appended
#
# ==== Examples
#
# puts make_testrail_time("2.34") # "2s"
def make_testrail_time(seconds_string)
  # If time is 0, make it 1
  rounded_time = [seconds_string.to_f.round, 1].max
  # Test duration
  time_elapsed = "#{rounded_time}s"

  return time_elapsed
end


##################################
# Junit and Beaker file functions
##################################

# Loads the results of a beaker run.
# Returns hash of failures, passes, and skips that each hold a list of 
# junit xml objects
#
# ==== Attributes
#
# * +junit_file+ - Path to a junit xml file
# 
# ==== Returns
#
# +hash+ - A hash containing xml objects for the failures, skips, and passes
#
# ==== Examples
#
# load_junit_results("~/junit/latest/beaker_junit.xml")
def load_junit_results(junit_file)
  junit_doc = Nokogiri::XML(File.read(junit_file))

  failures = junit_doc.xpath('//testcase[failure]')
  skips = junit_doc.xpath('//testcase[skip]')
  passes = junit_doc.xpath('//testcase[not(failure) and not(skip)]')

  return {failures: failures, skips: skips, passes: passes}
end


# Extracts the test case id from the test script
#
# ==== Attributes
#
# * +beaker_file+ - Path to a beaker test script
# 
# ==== Returns
#
# +string+ - The test case ID
#
# ==== Examples
#
# testcase_id_from_beaker_script("~/tests/test_the_things.rb") # 1234
def testcase_id_from_beaker_script(beaker_file)
  # Find first matching line
  match = File.readlines(beaker_file).map { |line| line.match(TESTCASE_ID_REGEX) }.compact.first

  match[:testrun_id]
end


# Calculates the path to a beaker test file by combining the junit file path
# with the test name from the junit results.
# Makes the assumption that junit folder that beaker creates will always be 
# 2 directories up from the beaker script base directory.
# TODO somewhat hacky, maybe a config/command line option
#
# ==== Attributes
#
# * +junit_file_path+ - Path to a junit xml file
# * +junit_result+ - Path to a junit xml file
# 
# ==== Returns
#
# +string+ - The path to the beaker script from the junit test result
#
# ==== Examples
#
# load_junit_results("~/junit/latest/beaker_junit.xml")
def beaker_test_path(junit_file_path, junit_result)
  beaker_folder_path = junit_result[:classname]
  test_filename = junit_result[:name]

  File.join(File.dirname(junit_file_path), "../../", beaker_folder_path, test_filename)
end


if __FILE__ == $PROGRAM_NAME
  main parse_opts
end
