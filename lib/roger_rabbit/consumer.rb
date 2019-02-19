##
# Usage: RogerRabbit::Consumer.get_instance_for_queue('test').consume do |body|
#   success = do_something(body)
#   should return true | false
# end

module RogerRabbit
  class Consumer < Base

    def consume(&block)
      begin
        queue_config = self.class.get_queue_config(@current_queue.name)

        @current_queue.subscribe(block: true, manual_ack: true) do |_delivery_info, _properties, body|
          success = block.call(body, _properties)

          unless success
            # Taken from https://felipeelias.github.io/rabbitmq/2016/02/22/rabbitmq-exponential-backoff.html
            headers      = _properties.headers || {}

            dead_headers = headers.fetch("x-death", []).last || {}
            retry_count  = headers.fetch("x-retry-count", 0)

            expiration   = dead_headers.fetch("original-expiration", 10000).to_i

            max_retry_count = queue_config.fetch(:max_retry_count, 0)
            retriable = queue_config.fetch(:retriable, false)
            exponential_backoff_factor = queue_config.fetch(:exponential_backoff_factor, 1.1)

            if retriable && retry_count < max_retry_count
              # Set the new expiration with an increasing factor
              new_expiration = expiration * exponential_backoff_factor

              # Publish to retry queue with new expiration
              self.get_retry_queue_for(@current_queue.name).publish(body, expiration: new_expiration.to_i, headers: {
                "x-retry-count": retry_count + 1
              })
            else
              self.get_dead_queue_for(@current_queue.name).publish(body)
            end
          end
          @channel.acknowledge(_delivery_info.delivery_tag, false)
        end
      rescue Interrupt => _
        self.close

        exit(0)
      end
    end
  end
end
