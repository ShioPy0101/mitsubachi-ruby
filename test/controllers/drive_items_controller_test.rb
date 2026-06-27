require "test_helper"

class DriveItemsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get drive_items_index_url
    assert_response :success
  end

  test "should get show" do
    get drive_items_show_url
    assert_response :success
  end
end
