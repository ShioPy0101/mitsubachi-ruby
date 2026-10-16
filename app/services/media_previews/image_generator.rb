module MediaPreviews
  # libvips で raster image を一覧向け JPEG へ縮小する。
  class ImageGenerator
    class ToolUnavailable < StandardError; end

    def call(input_path:, output_path:)
      # libvips が未導入でもアプリ全体とcache hit配信は起動できるよう、初回生成時までloadしない。
      require "image_processing/vips"
      ImageProcessing::Vips
        .source(input_path)
        .resize_to_limit(CachePath::SIZE, CachePath::SIZE)
        .convert("jpg")
        .saver(Q: 70, strip: true)
        .call(destination: output_path)
    rescue LoadError => error
      raise ToolUnavailable, error.message
    end
  end
end
