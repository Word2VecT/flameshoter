# Flameshoter 0.2.5

Adds Share beside Save in the capture toolbar. It opens Apple's NSSharingServicePicker with the rendered selection and annotations. The system supplies available destinations such as AirDrop, Messages, Mail and installed share extensions.

Cancelling the picker or a sharing service returns to the capture. After choosing a destination the capture overlay hides so the system service can present its interface; the capture session ends only when sharing completes. No image is uploaded by Flameshoter itself.

Existing native settings gain the Share button once, while keeping other toolbar choices and shortcuts. It can be hidden in Toolbar settings, and a shortcut can be assigned in Shortcuts. Retains the native layout, compact settings, stable signing identity and menu-bar behavior from 0.2.4.
