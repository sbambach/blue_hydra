module BlueHydra
  # This class is responsible for generating the CLI user interface views. Its
  # a bit crusty and probably could stand for a loving refactor someday.
  #
  # Someday soon...
  class CliUserInterface
    attr_accessor :runner, :cui_timeout, :l2ping_threshold

    # When we initialize this CUI we pass the runner which allows us to pull
    # information about the threads and queues for our own purposes
    def initialize(runner, cui_timeout=300)
      @runner = runner
      @cui_timeout = cui_timeout
      @l2ping_threshold = (@cui_timeout - 45)
    end

    # the following methods are simply alliasing data to be passed through from
    # the actual runner class
    def cui_status
      @runner.cui_status
    end

    def scanner_status
      @runner.scanner_status
    end

    def ubertooth_thread
      @runner.ubertooth_thread
    end

    def result_queue
      @runner.result_queue
    end

    def info_scan_queue
      @runner.info_scan_queue
    end

    def l2ping_queue
      @runner.l2ping_queue
    end

    def query_history
      @runner.query_history
    end

    # This is the message that gets printed before starting the CUI. It waits
    # til the user hits [Enter] before returning
    def help_message
      puts "\e[H\e[2J"

      msg =  <<HELP
Welcome to \e[34;1mBlue Hydra\e[0m

This will display live information about Bluetooth devices seen in the area.
Devices in this display will time out after #{cui_timeout}s but will still be
available in the BlueHydra Database or synced to pulse if you chose that
option.  #{ BlueHydra.config["file"] ? "\n\nReading data from " + BlueHydra.config["file"]  + '.' : '' }

The "VERS" column in the following table shows mode and version if available.
        CL/BR = Classic mode
        CL4.0 = Classic mode, version 4.0
        BTLE = Bluetooth Low Energy mode
        LE4.1 = Bluetooth Low Energy mode, version 4.1

The "RANGE" column shows distance in meters from the device if known.

Press "s" to change sort to the next column to the right (then enter)
Press "S" to change sort to the next column to the left (then enter)
Press "r" to reverse the sort order (then enter)
Press "c" to change the column set (then enter)

press [Enter] key to continue....
HELP

puts msg

gets.chomp
    end

    # the main work loop which prints the actual data to screen
    def cui_loop
      reset   = false # determine if we need to reset the loop by restarting method
      sort  ||= :rssi # default sort attribute
      order ||= "ascending" #default sort order

      # set default printable keys, aka column headers
      printable_keys ||= [
        :_seen, :vers, :address, :rssi, :name, :manuf, :type, :range
      ]

      #set default minimum set of sortable keys
      sortable_keys ||= [
        :last_seen, :vers, :address, :rssi
      ]

      # if we are in debug mode we will also print the UUID so we can figure
      # out what record is being displayed in the DB
      if BlueHydra.config["log_level"] == 'debug'
        unless printable_keys.include?(:uuid)
          printable_keys.unshift :uuid
        end
      end

      # figure out the terminal height using tput command
      max_height = `tput lines`.chomp.to_i

      until reset do
        trap("SIGWINCH") do
          # when we we get SIGWINCH we want to reset the display so we break
          # the loop and call this method again recursively at the end
          reset = true
        end

        # read 1 character from standard in
        input = STDIN.read_nonblock(1) rescue nil

        # handle the input character
        case
        when input == "s" # change key used for sorting moving left to right
          if sort == sortable_keys.last
            # if current key is last key we just rotate back to the first key
            sort = sortable_keys.first

          elsif sortable_keys.include?(sort)
            # if the key we are sorting on is included (ie columns haven't
            # changed) increment the index of the key used to go to the
            # next column for sorting
            sort = sortable_keys[sortable_keys.index(sort) + 1]
          else
            # TODO is this needed with below?
            # default sort order
            sort = :rssi
          end
        when input == "S" # change key used for sorting moving right to left
          if sort == sortable_keys.first
            # if current key is first key we just rotate back to the last key
            sort = sortable_keys.last

          elsif sortable_keys.include?(sort)
            # if the key we are sorting on is included (ie columns haven't
            # changed) increment the index of the key used to go to the
            # next column for sorting
            sort = sortable_keys[sortable_keys.index(sort) - 1]
          else
            # TODO is this needed with below?
            # default sort order
            sort = :rssi
          end
        when ["r","R"].include?(input) # toggle sort order
          if order == "ascending"
            order = "descending"
          elsif order == "descending"
            order = "ascending"
          end
        when input == "c" # toggle alternate keys
          if printable_keys.include?(:le_proximity_uuid)
            [
              :le_proximity_uuid,
              :le_major_num,
              :le_minor_num
            ].each {|k| printable_keys.delete(k)}
            printable_keys += [ :company, :le_company_data ]
          elsif printable_keys.include?(:company)
            [
              :company,
              :le_company_data
            ].each {|k| printable_keys.delete(k)}
          else
            printable_keys += [
              :le_proximity_uuid, :le_major_num, :le_minor_num
            ]
          end
        end


        # render the cui with and get back list of currently sortable keys for
        # next iteration of loop
        sortable_keys = render_cui(max_height,sort,order,printable_keys)
        if sortable_keys.nil? || !sortable_keys.include?(sort)
          # if we have remove the column we were sorting on
          # reset the sort order to RSSI
          sort = :rssi
        end

        sleep 0.1
      end

      # once reset has been triggered we need to reset this method so
      # we just call it again on top of itself
      cui_loop
    end

    # this method gets called over and over in the cui loop to print the data
    # table
    #
    # == Parameters:
    #   max_height ::
    #     integer value for height of output terminal
    #   sort ::
    #      symbol key to indicate what attribute table should be sorted on
    #   order ::
    #     symbol key to determine if we should reverse the sort order from asc
    #     to desc
    #   printable_keys ::
    #     list of keys to be printed as table headers
    def render_cui(max_height,sort,order,printable_keys)
      begin

        # skip if we are reading from a file
        unless BlueHydra.config["file"]
          # check status of test discovery
          if scanner_status[:test_discovery]
            discovery_time = Time.now.to_i - scanner_status[:test_discovery]
          else
            discovery_time = "not started"
          end

          # check status of ubertooth
          if ubertooth_thread
            if scanner_status[:ubertooth]
              ubertooth_time = Time.now.to_i - scanner_status[:ubertooth]
            else
              ubertooth_time = "not started"
            end
          else
            ubertooth_time = "not enabled"
          end
        end

        # pbuff is the print buffer we build up to write to the screen, each
        # time we append lines to pbuff we need to increment the lines count
        # so that we know how many lines we are trying to output.
        pbuff = ""
        lines = 1

        # clear screen, doesn't require line increment cause it wipes
        # everything
        pbuff << "\e[H\e[2J"

        # first line, blue hydra wrapped in blue
        pbuff << "\e[34;1mBlue Hydra\e[0m :"
        # unless we are reading from a file we will ad this to the first line
        unless BlueHydra.config["file"]
          pbuff <<  " Devices Seen in last #{cui_timeout}s"
        end
        pbuff << "\n"
        lines += 1

        # second line, information about runner queues to help determine if we
        # have a backlog. backlogs mean that the data being displayed may be
        # delayed
        pbuff << "Queue status: result_queue: #{result_queue.length}, info_scan_queue: #{info_scan_queue.length}, l2ping_queue: #{l2ping_queue.length}\n"
        lines += 1

        # unless we are reading from a file we add a line with information
        # about the status of the discovery and ubertooth timers from the
        # runner
        unless BlueHydra.config["file"]
          pbuff <<  "Discovery status timers: #{discovery_time}, ubertooth status: #{ubertooth_time}\n"
          lines += 1
        end

        # initialize a hash to track column widths, default value is 0
        max_lengths = Hash.new(0)

        # guide for how we should justify (left / right), default is left so
        # really only adding overrides at this point.
        justifications = {
          _seen: :right,
          rssi:  :right,
          range: :right
        }


        # remove devices from the cui_status which have expired
        unless BlueHydra.config["file"]
          cui_status.keys.select do |x|
            cui_status[x][:last_seen] < (Time.now.to_i - cui_timeout)
          end.each do |x|
            cui_status.delete(x)
          end
        end

        # nothing to do if cui_status is empty (no devices or all expired)
        unless cui_status.empty?

          # for each of the values we need to
          cui_status.values.each do |hsh|
            # fake a :_seen key with info derived from the :last_seen value
            hsh[:_seen] = " +#{Time.now.to_i - hsh[:last_seen]}s"
            # loop through the keys and figure out what the max value for the
            # width of the column is. This includes the length of the actual
            # header key itself
            printable_keys.each do |key|
              key_length = key.to_s.length
              if v = hsh[key].to_s
                if v.length > max_lengths[key]
                  if v.length > key_length
                    max_lengths[key] = v.length
                  else
                    max_lengths[key] = key_length
                  end
                end
              end
            end
          end

          # select the keys which have some value greater than 0
          keys = printable_keys.select{|k| max_lengths[k] > 0}

          # reusable proc for formatting the keys
          prettify_key = Proc.new do |key|

            # shorten some names
            k = case key
              when :le_major_num
                :major
              when :le_minor_num
                :minor
              else
                key
              end

            # upcase the ky
            k = k.upcase

            # if the key is the same as the sort value we need to add an
            # indicator and also determine if the values are sorted ascending
            # (^) or descending (v)
            if key == sort

              # determin order and add the sort indicator to the key
              z = order == "ascending" ? "^" : "v"
              k = "#{k} #{z}"

              # expand max length for the key column if adding the sort
              # indicator makes the key length greater than the current
              # tracked length for the column width
              if k.length > max_lengths[key]
                max_lengths[key] = k.length
              end
            end

            # replace underscores with spaces and left justify
            k.to_s.ljust(max_lengths[key]).gsub("_"," ")
          end

          # map across the keys and use the pretify key to clean up the key
          # before joining with | characters to create the header row
          header = keys.map{|k| prettify_key.call(k)}.join(' | ')

          # underline and add to pbuff
          pbuff << "\e[0;4m#{header}\e[0m\n"
          lines += 1

          # customize some of the sort options to handle integer values
          # which may be string wrapped in strange ways
          d = cui_status.values.sort_by do |x|
            if sort == :rssi || sort == :_seen
              x[sort].to_s.strip.to_i
            elsif sort == :range
              x[sort].strip.to_f rescue 2**256
            else
              # default sort is alpha sort
              x[sort].to_s
            end
          end

          # rssi values are neg numbers and so we want to just go ahead and
          # reverse the sort to beging by default
          if sort == :rssi
            d.reverse!
          end

          # if order is reverse we should go ahead and reverse the table data
          if order == "descending"
            d.reverse!
          end

          # iterate across the  sorted data
          d.each do |data|
            #prevent classic devices from expiring by forcing them onto the l2ping queue
            unless BlueHydra.config["file"]
              if data[:vers] =~ /cl/i
                ping_time = (Time.now.to_i - l2ping_threshold)
                query_history[data[:address]] ||= {}
                if (query_history[data[:address]][:l2ping].to_i < ping_time) && (data[:last_seen] < ping_time)
                  l2ping_queue.push({
                    command: :l2ping,
                    address: data[:address]
                  })

                  query_history[data[:address]][:l2ping] = Time.now.to_i
                end
              end
            end

            # stop printing if we are at the max_height value. this is why
            # incrementing lines is important
            next if lines >= max_height

            # choose a color code for the row based on how recently its been
            # since initially detecting
            color = case
                    when data[:created] > Time.now.to_i - 10  # in last 10 seconds
                      "\e[0;32m" # green
                    when data[:created] > Time.now.to_i - 30  # in last 30 seconds
                      "\e[0;33m" # yellow
                    when data[:last_seen] < (Time.now.to_i - cui_timeout + 20) # within 20 seconds expiring
                      "\e[0;31m" # red
                    else
                      ""
                    end

            # for each key determin if the data should be left or right
            # justified
            x = keys.map do |k|

              if data[k]
                if justifications[k] == :right
                  data[k].to_s.rjust(max_lengths[k])
                else
                  v = data[k]
                  if BlueHydra.demo_mode
                    if k == :address
                      mac_chars = "A-F0-9:"
                      v = v.gsub(
                        /^[#{mac_chars}]{5}|[#{mac_chars}]{5}$/,
                        '**:**'
                      )
                    end
                  end
                  v.to_s.ljust(max_lengths[k])
                end
              else
                ''.ljust(max_lengths[k])
              end
            end

            # join the data after justifying and add to the pbuff
            #
            # We did it! :D
            pbuff <<  "#{color}#{x.join(' | ')}\e[0m\n"
            lines += 1
          end
        else
          # when empty just tack onthis line to the pbuff
          pbuff <<  "No recent devices..."
        end

        # print the entire pbuff to screen! ... phew
        puts pbuff

        # keys are returned back to the cui_loop so it can update its
        # pre-processing for sort etc
        return keys

      rescue => e
        BlueHydra.logger.error("CUI thread #{e.message}")
        e.backtrace.each do |x|
          BlueHydra.logger.error("#{x}")
        end
      end
    end
  end
end
