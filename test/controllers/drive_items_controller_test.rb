require "test_helper"

class DriveItemsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get drive_items_url
    assert_response :unauthorized
  end

  test "should get show" do
    get drive_item_url(drive_items(:one))
    assert_response :unauthorized
  end
end
