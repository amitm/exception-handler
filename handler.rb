require 'pathname'
require 'json'
require 'yaml'

require 'thin'
require 'sinatra'
require 'httpclient'
require 'hipchat'


RB_ACCESS_TOKEN = ENV['ROLLBAR_ACCESS_TOKEN']
RB_URL = "https://api.rollbar.com/api/1/instance/"\
              "%{instance_id}?access_token=#{RB_ACCESS_TOKEN}"

HC_ACCESS_TOKEN = ENV['HIPCHAT_ACCESS_TOKEN']
HC_EXCEPTION_ROOM = 'New Exceptions'

config = YAML.load_file('config.yml')
HC_USERNAMES = config['users']
HC_CLIENT = HipChat::Client.new(HC_ACCESS_TOKEN)

BLAME_REGEXP = /^[^\(]+\((.*)[0-9]{4}-[0-1]/

# need to find the first thing that starts with /www/AngelList
def get_error_frame(trace)
  trace.reverse.find { |f| !f['filename'].start_with?('/usr/local/rvm/') }
end

def get_annotation(frame)
  path = Pathname.new(frame['filename'])
  `cd #{path.dirname}; git annotate #{frame['filename']} -L#{frame['lineno']},#{frame['lineno']}`
end

def get_offender_hc_username(annotation)
  match = BLAME_REGEXP.match(annotation)
  HC_USERNAMES[match[1].strip()] if match
end

def get_rollbar_url(item_id)
  "https://rollbar.com/item/#{item_id}"
end

def link_to(url)
  "<a href='#{url}'>#{url}</a>"
end

def generate_message(item)
  error = [
    "<b>#{item['last_occurrence']['context']}:</b> #{item['title']}",
    "#{link_to(item['last_occurrence']['request']['url'])}"
  ]
  if person = item['last_occurrence']['person']
    error << "User: #{person['email']} "\
             "#{link_to("https://angel.co/#{person['username']}")}"
  end
  error << link_to(get_rollbar_url(item['id']))
  if frame = get_error_frame(item['last_occurrence']['body']['trace']['frames'])
    annotation = get_annotation(frame)
    unless annotation.empty?
      error << "Blame: #{annotation}"
      if username = get_offender_hc_username(annotation)
        error << "@#{username}"
      end
    end
  end
  error.join('<br>')
end

def send_message(message)
  HC_CLIENT[HC_EXCEPTION_ROOM].send('ExceptionBot', message,
                                    message_format: 'html',
                                    notify: 1)
end

post '/rollbar' do
  data = JSON.parse(request.body.read)
  item = data['data']['item']
  return unless item
  send_message(generate_message(item))
end
