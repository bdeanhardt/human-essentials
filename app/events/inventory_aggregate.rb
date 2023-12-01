module InventoryAggregate
  class << self
    # @param event_types [Array<Class<Event>>]
    def on(*event_types, &block)
      @handlers ||= {}
      event_types.each do |event_type|
        @handlers[event_type] = block
      end
    end

    # @param organization_id [Integer]
    # @param first_event [Integer]
    # @param last_event [Integer]
    # @return [EventTypes::Inventory]
    def inventory_for(organization_id, first_event: nil, last_event: nil)
      events = Event.for_organization(organization_id)
      if first_event
        events = events.where('id >= ?', first_event)
      end
      if last_event
        events = events.where('id <= ?', last_event)
      end
      inventory = EventTypes::Inventory.from(organization_id)
      events.group_by { |e| [e.eventable_type, e.eventable_id] }.each do |_, event_batch|
        last_grouped_event = event_batch.max_by(&:updated_at)
        handle(last_grouped_event, inventory)
      end
      inventory
    end

    # @param event [Event]
    # @param inventory [Inventory]
    def handle(event, inventory)
      handler = @handlers[event.class]
      if handler.nil?
        Rails.logger.warn("No handler found for #{event.class}, skipping")
        return
      end
      handler.call(event, inventory)
    end

    # @param payload [EventTypes::InventoryPayload]
    # @param inventory [EventTypes::Inventory]
    # @param validate [Boolean]
    def handle_inventory_event(payload, inventory, validate: true)
      payload.items.each do |line_item|
        inventory.move_item(item_id: line_item.item_id,
          quantity: line_item.quantity,
          from_location: line_item.from_storage_location,
          to_location: line_item.to_storage_location,
          validate: validate)
      end
    end

    # @param payload [EventTypes::InventoryPayload]
    # @param inventory [EventTypes::Inventory]
    # @param validate [Boolean]
    def handle_audit_event(payload, inventory)
      payload.items.each do |line_item|
        inventory.set_item_quantity(item_id: line_item.item_id,
          quantity: line_item.quantity,
          location: line_item.to_storage_location)
      end
    end
  end

  on DonationEvent, DistributionEvent, AdjustmentEvent, PurchaseEvent,
    TransferEvent, DistributionDestroyEvent, DonationDestroyEvent,
    PurchaseDestroyEvent, TransferDestroyEvent,
    KitAllocateEvent, KitDeallocateEvent do |event, inventory|
    handle_inventory_event(event.data, inventory, validate: false)
  end

  on AuditEvent do |event, inventory|
    handle_audit_event(event.data, inventory)
  end

  on SnapshotEvent do |event, inventory|
    inventory.storage_locations.clear
    inventory.storage_locations.merge!(event.data.storage_locations)
  end
end
