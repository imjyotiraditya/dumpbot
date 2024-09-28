from telegram.ext import ApplicationBuilder, CommandHandler

from dumpyarabot.handlers import cancel_dump, dump

from .config import settings

if __name__ == "__main__":
    application = ApplicationBuilder().token(settings.TELEGRAM_BOT_TOKEN).build()

    dump_handler = CommandHandler("dump", dump)
    cancel_dump_handler = CommandHandler("cancel", cancel_dump)
    application.add_handler(dump_handler)
    application.add_handler(cancel_dump_handler)

    application.run_polling()
