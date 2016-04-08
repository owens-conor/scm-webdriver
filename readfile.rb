require 'date'
require 'selenium-webdriver'
require 'pp'

STDOUT.sync = true

include Selenium::WebDriver::Error

useproxy = true

transactions_file = ARGV[0]
invoice_lookup_file = ARGV[1]
if ARGV.count > 2
  useproxy = false
end

invoice_lookup = Hash.new

# Debug logging for use with -d . Switched off
#DEBUG = true
def debug(line)
  log(line) if $DEBUG
end

# Logger - just uses puts for now
def log(line)
  puts line
end

##############################################################################
def fillfield(selector_type, selector, keys, opts={})
  tries = 0
  begin
    element = $driver.find_element(selector_type, selector)
    element.clear
    keys.each do |k|
      element.send_keys k
    end
  rescue NoSuchElementError
    tries += 1
    puts "Rescue for #{opts[:name] || "unknown"}: Try #{tries} Customer #{opts[:customer] || "unknown"} Txn date: #{opts[:txndate] || "unknown"}"
    sleep 1
    if tries < 3
      retry
    else
      #break
      raise "Break at #{opts[:name] || "unknown"}: Try #{tries} Customer #{opts[:customer] || "unknown"} Txn date: #{opts[:txndate] || "unknown"}"
    end
  end
  sleep 0.5
end


###############################################################################
### Read and store the invoice lookup file
File.foreach(invoice_lookup_file) do |line|
  n1,invoice = line.split(/,/)
  invoice_lookup[n1] = invoice.to_s.chomp
  debug "n1 #{n1} invoice #{invoice_lookup[n1]}"
end

### Login to the gbsc site
ENV['no_proxy'] = "127.0.0.1"
PROXY = 'web-proxy.corp.hpecorp.net:8080'

profile = Selenium::WebDriver::Firefox::Profile.new
if useproxy
  puts "SETTING PROXY"
  profile.proxy = Selenium::WebDriver::Proxy.new(
    :http     => PROXY,
    :ftp      => PROXY,
    :ssl      => PROXY
  )
end

driver = Selenium::WebDriver.for :firefox, :profile => profile
driver.manage.timeouts.implicit_wait = 10 # seconds

$driver = driver
driver.get "http://gbsc.clubmin.net"

driver.find_element(:id, 'user_email')
      .send_keys "owens.conor@gmail.com"

driver.find_element(:id, 'user_password')
      .send_keys "XLHJ4J"

driver.find_element(:name, 'commit').click

### End of Login

### Loop through bank transactions
current_n1 = "SOMECRAPHERE"
alreadypaid = {}
alreadypaid["AA"] = "AA"
File.foreach(transactions_file) do |txn|
  next unless txn =~ /^985750/
  next unless txn =~ /AINE NOLAN/
  values = txn.split(/,/)
  txndate = values[9].to_s
  txnn1 = values[10].to_s
  txncredit = values[17].chomp.to_s
  # If txncredit doesn't end with '.00' then add it. Some bank files do, some bank files don't.
  if ! txncredit =~ /.*\.00$/
    txncredit = txncredit + ".00"
  end
  webtxndate = Date.strptime("#{txndate}", '%d/%m/%Y').strftime("%-e %b %Y")
  debug "date #{txndate} n1 #{txnn1} credit #{txncredit} webtxndate #{webtxndate}"

  ## Move on if this n1 not in invoice lookup
  if invoice_lookup.has_key?(txnn1)

    ### Are we on same or new n1
    if txnn1 != current_n1
      puts "New Customer #{txnn1} --------------------------------------------------------"
      ### Reset for this customer
      current_n1 = txnn1
      current_invoice = invoice_lookup[current_n1].to_s
      puts "customer #{txnn1} invoice #{current_invoice} webtxndate #{webtxndate} credit #{txncredit}"
      alreadypaid = {}
      alreadypaid["XX"] = "XX"

      ### Navigate to invoice page in SCM
      element = driver.find_element(:id, 'all') # search box
      element.send_keys current_invoice
      element.send_keys:return

      driver.find_element(:link_text, current_invoice).click

      ### Check transaction dates already paid for this invoice
      ### existing payments which are stored
      ### in:   ".//*[@id='core']/div[3]/div[2]/div[2]/table/tbody[1]/tr[5]/td[1]"
      ### or:   ".//*[@id='core']/div[3]/div[2]/div[3]/table/tbody[1]/tr[5]/td[1]"
      ### paid: ".//*[@id='core']/div[3]/div[2]/div[2]"
      ### from tr[5] onwards

      ### Check for paid message
      div = 2
      begin
        if driver.find_element(:xpath, ".//*[@id='core']/div[3]/div[2]/div[2]").text =~ /This invoice was paid/
          div = 3
        end
      rescue
        div = 2
      end

      ### Print out the name on the invoice as a Check
      ### Can be at : .//*[@id='core']/div[3]/div[2]/div[2]/div[1]/p/a
      ### or at     : .//*[@id='core']/div[3]/div[2]/div[3]/div[1]/p/a if invoice paid.
      begin
        puts "invoice #{current_invoice} belongs to " + driver.find_element(:xpath, ".//*[@id='core']/div[3]/div[2]/div[#{div}]/div[1]/p/a").text
        #.//*[@id='core']//div//a[starts-with(@href, "/contact")]
      rescue
        puts "could not find invoice owner for #{current_invoice} -- please check"
      end
      $stdout.flush

      tr = 5
      print "Paid so far:"
      loop do
        begin
          # .//*[@id='core']//div//table/tbody[1]/tr[#{tr}]/td[1]
          if driver.find_element(:xpath, ".//*[@id='core']/div[3]/div[2]/div[#{div}]/table/tbody[1]/tr[#{tr}]/td[1]")
            paidline = driver.find_element(:xpath, ".//*[@id='core']/div[3]/div[2]/div[#{div}]/table/tbody[1]/tr[#{tr}]/td[1]").text
            paidline = paidline.gsub(/^.*Payment received *(.*) into.*$/, '\1')
            print " #{paidline}"
            alreadypaid[paidline] = paidline
            tr += 1
            debug alreadypaid
          end
        rescue NoSuchElementError
          debug "Element not found for tr #{tr}."
          debug alreadypaid
          break
        end
      end # loop do
      print "\n"
      $stdout.flush
      sleep 1
    end #same or new

    print "Customer #{current_n1} Txn date: #{webtxndate}"
    ### We should already be on the invoice page

    ### Check txns against alreadypaid
    debug ">#{webtxndate}<"
    #pp alreadypaid
    #pp alreadypaid["#{webtxndate}"]
    if alreadypaid.has_value?("#{webtxndate}")
      print " - Already paid #{webtxndate}\n"
    else
      print " - Paying #{webtxndate} #{txncredit}\n"
      ### click on the allocate payment (not there is invoice is paid)
      begin
        driver.find_element(:xpath, ".//*[@id='core']/div[1]/div/a").click
      rescue NoSuchElementError
        puts "Could not find the allocate payment button for #{current_invoice} for #{current_n1} ------------"
        next
      end
      $stdout.flush

      ### click on GBSC01
      driver.find_element(:xpath, ".//*[@id='core']/div[1]/div/ul/li[1]/a").click
      sleep 2

      ### Input date received
=begin
      fillfield (
        :id, 'date_received',
        [webtxndate, :return],
        :name => 'input date received',
        :customer => current_n1,
        :txndate => webtxndate
      )
=end

      tries = 0
      begin
        element = driver.find_element(:id, 'date_received')
        element.clear
        element.send_keys webtxndate
        element.send_keys:return
      rescue NoSuchElementError
        tries += 1
        puts "Rescue for input date received: Try #{tries} Customer #{current_n1} Txn date: #{webtxndate}"
        sleep 1
        if tries < 3
          retry
        else
          break
        end
      end
      sleep 0.5

      ### Input amount
      tries = 0
      begin
        element = driver.find_element(:id, 'bank_account_entry_amount')
        element.clear
        element.send_keys "#{txncredit}"
      rescue NoSuchElementError
        tries += 1
        puts "Rescue for bank_account_entry_amount: Try #{tries} Customer #{current_n1} Txn date: #{webtxndate}"
        sleep 1
        if tries < 3
          retry
        else
          break
        end
      end
      sleep 0.5
      ### Input allocations amount
      #element = driver.find_element(:id, 'bank_account_entry_bank_allocations_attributes__amount')
      tries = 0
      begin
        element = driver.find_element(:xpath, ".//*[@id='bank_account_entry_bank_allocations_attributes__amount']")
        element.clear
        element.send_keys "#{txncredit}"
      rescue NoSuchElementError
        tries += 1
        puts "Rescue for allocations_attributes__amount: Try #{tries} Customer #{current_n1} Txn date: #{webtxndate}"
        sleep 1
        if tries < 3
          retry
        else
          break
        end
      end
      sleep 0.5
      ### Click save
      driver.find_element(:name, 'commit').click
      alreadypaid[webtxndate] = webtxndate
      sleep 2
    end
  else
    log "No invoice lookup found for #{txnn1}"
  end
  $stdout.flush
end # txn

driver.get "http://gbsc.clubmin.net/users/logout"

driver.quit

__END__
